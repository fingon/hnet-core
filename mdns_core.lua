#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 15:07:49 2012 mstenber
-- Last modified: Wed Dec 19 04:10:20 2012 mstenber
-- Edit time:     187 min
--

-- This module contains the main mdns algorithm; it is not tied
-- directly to socket, event loop, or time functions. Instead,
-- bidirectional API is assumed to address those.

-- API from outside => mdns:
-- - run() - perform one iteration of whatever it does
-- - next_time() - when to run next time
-- - recvmsg(from, data)
-- - skv 
--    ospf-lap ( to check if master, or not )
--    ospf-mdns = {} (?)

-- API from mdns => outside:
-- - time() => current timestamp
-- - sendmsg(to, data)
--=> skv
--    mdns.if = .. ?

-- Internally, implementation has two different data structures per if:

-- - cache (=what someone has sent to us, following the usual TTL rules)

-- - own (=what we want to publish on the link, following the state
--   machine for each record)

-- TODO: 

--  - deal with mdns + ospf-mdns skv stuff (rw)
--  ( perhaps treat them as interface that 'everyone' owns, and cache
--  = what we get from others, own = what we publish)

--  - state machine for published entries (handle reception triggers -
--    now basic send sequence works)

require 'mst'
require 'dnscodec'
require 'dnsdb'

module(..., package.seeall)

MDNS_MULTICAST_ADDRESS='ff02::fb'

-- probing states (waiting to send message N)
STATE_P1='p1'
STATE_P2='p2'
STATE_P3='p3'
STATE_PW='pw'
-- => a1 if no replies

-- waiting to start probe again
STATE_WP1='wp1' 

-- announce states - waiting to announce (based on spam-the-link frequency)
STATE_A1='a1'
STATE_A2='a2'

-- waiting to announce ttl 0
STATE_D1='d1'
-- waiting to die after ttl 0 sent (1 second)
STATE_D2='d0'

-- when do we call the 'run' method for a state after we have entered the state?
STATE_DELAYS={[STATE_P1]={0, 250},
              [STATE_P2]={250, 250},
              [STATE_P3]={250, 250},
              [STATE_PW]={250, 250},
              [STATE_WP1]={1000, 1000},
              [STATE_A1]={20, 120},
              [STATE_A2]={1000, 1000},
              [STATE_D1]={20, 120},
              [STATE_D2]={1000, 1000},
}

function send_probes_cb(self, ifname, rr)
   -- send _all_ probes, and implicitly advance them to next step too
   self:send_probes(ifname)
end

function send_announces_cb(self, ifname, rr)
   self:send_announces(ifname)
end

STATE_CALLBACKS={[STATE_P1]=send_probes_cb,
                 [STATE_P2]=send_probes_cb,
                 [STATE_P3]=send_probes_cb,
                 [STATE_A1]=send_announces_cb,
                 [STATE_A2]=send_announces_cb,
}

NEXT_STATES={[STATE_P1]=STATE_P2,
             [STATE_P2]=STATE_P3,
             [STATE_P3]=STATE_PW,
             [STATE_PW]=STATE_A1,
             [STATE_WP1]=STATE_P1,
             [STATE_A1]=STATE_A2,
             [STATE_A2]=false,
             [STATE_D1]=STATE_D2,
}


mdns = mst.create_class{class='mdns', 
                        time=os.time,
                        mandatory={'sendmsg', 'skv'}}

function mdns:init()
   -- per-if ns of entries received from network
   self.if2cache = {}
   -- per-if ns of entries we want to publish to that particular network
   self.if2own = {}
   -- array of pending queries we haven't answered to, yet
   self.queries = {} 
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
end

function mdns:repr_data()
   return '?'
end

function mdns:kv_changed(k, v)
   if k == elsa_pa.OSPF_LAP_KEY
   then
      self:d('queueing lap update')

      self.ospf_lap = v
      self.update_lap = true
      self.master_if_set = self:calculate_if_master_set()
   end
end

function mdns:uninit()
   self.skv:remove_change_observer(self.f)
end

function mdns:run()
   local fresh = {}
   local removed = {}
   if self.update_lap
   then
      self:d('running lap update')

      self.update_lap = nil
      self:d('syncing if2own')
      mst.sync_tables(self.if2own, self.master_if_set,
                      -- remove spurious
                      function (k, v)
                         if v.active
                         then
                            self:d(' removing ', k)
                            self:remove_own_from_if(k)
                            self:remove_own_to_if(k)
                            v.active = nil
                         end
                      end,
                      -- add missing
                      function (k, v)
                         self:d(' adding ', k)
                         local ns = self:get_if_own(k)
                         table.insert(fresh, ns)
                         ns.active = true
                      end
                      -- comparison omitted -> we don't _care_
                     )
      if mst.table_count(fresh) > 0
      then
         local non_fresh = self.master_if_set:difference(fresh)
         if non_fresh:count() > 0
         then
            self:add_cache_set_to_own_set(non_fresh, fresh)
         end
      end
   end

   -- iteratively run through the object states until all are waiting
   -- for some future timestamp
   while self:run_own_states() > 0 do end
end


function mdns:run_own_states()
   local now = self.time()
   local c = 0
   -- for each interface with non-empty own set, check what we can do
   for ifname, ns in pairs(self.if2own)
   do
      local pending = {}
      for i, rr in ipairs(ns:values())
      do
         if rr.state
         then
            if rr.wait_until and rr.wait_until <= now then rr.wait_until = nil end

            if not rr.wait_until
            then
               pending[rr] = rr.state
            end
         end
      end
      for rr, state in pairs(pending)
      do
         if rr.state == state
         then
            self:run_state(ifname, rr)
            c = c + 1
         end
      end
   end
   return c
end


function mdns:get_if_cache(ifname)
   local ns = self.if2cache[ifname]
   if not ns 
   then
      ns = dnsdb.ns:new{}
      self.if2cache[ifname] = ns
   end
   return ns
end

function mdns:get_if_own(ifname)
   local ns = self.if2own[ifname]
   if not ns 
   then
      ns = dnsdb.ns:new{}
      self.if2own[ifname] = ns
   end
   return ns
end

function mdns:recvmsg(src, data)
   local l = mst.string_split(src, '%')
   mst.a(#l == 2, 'invalid src', src)
   local addr, ifname = unpack(l)
   local msg = dnscodec.dns_message:decode(data)
   -- XXX - better handling
   local ns = self:get_if_cache(ifname)
   for i, rr in ipairs(msg.an or {})
   do
      local old_rr = ns:find_rr(rr)
      if old_rr
      then
         -- XXX - is this the thing to do?
         ns:insert_rr(rr)
      else
         ns:insert_rr(rr)
      end
      -- propagate information if and only if master of that interface
      if self.master_if_set[ifname] and not self:rr_has_conflicts(rr)
      then
         self:propagate_rr_from_if(rr, ifname)
      end
   end
end

function mdns:rr_has_conflicts(rr)
   -- look if we have cache_flush enabled rr in _some_ cache, that
   -- isn't _exactly_ same as this. if we do, it's a conflict
   -- (regardless of whether this one is cache_flush=true)
   for toif, ns in pairs(self.if2cache)
   do
      -- XXX - should we care if if is master or not?
      -- probably not

      -- unfortunately, we have to consider _all_ records that match
      -- the name => not insanely efficient.. but oh well. we know
      -- specifically what we're looking for, after all.
      for i, o in ipairs(ns:find_rr_list_for_ll(rr.name))
      do
         if o.cache_flush and o.rtype == rr.rtype and dnsdb.rr_contains(rr, o) and not dnsdb.rr_equals(rr, o)
         then
            self:d('found conflict for ', rr, o)
            return true
         end
      end
   end
end

function mdns:propagate_rr_from_if(rr, ifname)
   for toif, _ in pairs(self.master_if_set)
   do
      if toif ~= ifname
      then
         -- there isn't conflict - so we can just peacefully insert
         -- the rr to the own list
         self:insert_if_own_rr(toif, rr)
      end
   end
end

function mdns:remove_own_from_if(fromif)
   -- remove 'own' ns entries for all interfaces we're master to,
   -- that originate from the ifname 'ifname' cache
   local fromns = self.if2cache[fromif]
   if not fromns then return end
   
   -- (or well, not necessarily _remove_, but set their state
   -- s.t. they will be removed shortly)
   for i, toif in ipairs(self.master_if_set:keys())
   do
      local ns = self.if2own[toif]
      if ns
      then
         for i, rr in ipairs(fromns:values())
         do
            local nrr = ns:find_rr(rr)
            if nrr
            then
               nrr:expire()
            end
         end
      end
   end
end

function mdns:remove_own_to_if(ifname)
   local ns = self.if2own[ifname]
   if not ns then return end
   for i, rr in ipairs(ns:values())
   do
      -- XXX do more?
      ns:remove_rr(rr)
   end
end

function mdns:add_cache_set_to_own_set(fromset, toset)
   for i, src in ipairs(fromset)
   do
      for i, dst in ipairs(toset)
      do
         self:add_cache_if_to_own_if(src, dst)
      end
   end
end

function mdns:add_cache_if_to_own_if(fromif, toif)
   -- these are always cache => own mappings;
   -- we never do own=>own
   local src = self.if2cache[fromif]
   if not src then return end
   for i, rr in ipairs(src:values())
   do
      self:insert_if_own_rr(toif, rr)
   end
end

function mdns:insert_if_own_rr(ifname, rr)
   local ns = self:get_if_own(ifname)
   -- XXX - do something with the old?
   --local old_rr = ns:find_rr(rr)
   local o, is_new = ns:insert_rr(rr)
   if is_new
   then
      if o.cache_flush
      then
         self:set_state(ifname, o, STATE_P1)
      else
         self:set_state(ifname, o, STATE_A1)
      end
   end
   return o
end

function mdns:set_state(ifname, rr, st)
   local w = STATE_DELAYS[st]
   self:d('setting state', rr, st)
   rr.state = st
   if w
   then
      rr.wait_until = self.time() + mst.randint(w[1], w[2]) / 1000.0
      return
   end
   -- no wait => should run it immediately
   self:run_state(ifname, rr)
end

function mdns:set_next_state(ifname, rr)
   -- may just go to next state too
   local next = NEXT_STATES[rr.state]
   if next ~= nil
   then
      if next
      then
         self:set_state(ifname, rr, next)
      else
         -- done!
         rr.state = nil
      end
   end
end

function mdns:run_state(ifname, rr)
   -- inherent wait (if any) is done; execute the state callback
   local state = rr.state
   local cb = STATE_CALLBACKS[state]
   if cb
   then
      cb(self, ifname, rr)
   end
   -- if something happened automatically, skip next-state mechanism
   if rr.state ~= state
   then
      return
   end
   self:set_next_state(ifname, rr)
end

function mdns:lap_is_master(lap)
   local dep = lap.depracate      
   local own = lap.owner and not lap.external
   return not dep and own
end

function mdns:calculate_if_master_set()
   local t = mst.set:new{}
   for i, lap in ipairs(self.ospf_lap)
   do
      if self:lap_is_master(lap)
      then
         t:insert(lap.ifname)
      end
   end
   return t
end

function mdns:next_time()
   local best = nil
   for ifname, ns in pairs(self.if2own)
   do
      local pending = {}
      for i, rr in ipairs(ns:values())
      do
         if rr.state and rr.wait_until
         then
            if not best or rr.wait_until < best
            then
               best = rr.wait_until
            end
         end
      end
   end
   return best
end

function mdns:send_announces(ifname)
   -- try to send _all_ eligible announcements at once.
   -- e.g. entries that are in one of the send-announce states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self:get_if_own(ifname)
   local announce_states = {[STATE_A1]=true, [STATE_A2]=true}
   local an = {}
   for i, rr in ipairs(ns:values())
   do
      if announce_states[rr.state] and not rr.wait_until
      then
         -- xxx - do something more clever here?
         table.insert(an, rr)

         self:set_next_state(ifname, rr)
      end
   end
   -- XXX - actually packet an and send it out on ifname!
   -- XXX ( also, handle fragmentation )
   if #an > 0
   then
      local s = dnscodec.dns_message:encode{an=an}
      self.sendmsg(MDNS_MULTICAST_ADDRESS .. '%' .. ifname, s)
   end
end

function mdns:send_probes(ifname)
   -- try to send _all_ eligible probes at once.
   -- e.g. entries that are in one of the send-probe states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self:get_if_own(ifname)
   local probe_states = {[STATE_P1]=true, [STATE_P2]=true, [STATE_P3]=true}
   local qd = {}
   local ar = {}
   for i, rr in ipairs(ns:values())
   do
      if probe_states[rr.state] and not rr.wait_until
      then
         table.insert(qd, {qtype=rr.rtype,
                           qclass=rr.rclass,
                           name=rr.name})
         table.insert(ar, rr)

         self:set_next_state(ifname, rr)
      end
   end
   -- XXX ( also, handle fragmentation )
   if #qd > 0
   then
      local s = dnscodec.dns_message:encode{qd=qd, ar=ar}
      self.sendmsg(MDNS_MULTICAST_ADDRESS .. '%' .. ifname, s)
   end
end

