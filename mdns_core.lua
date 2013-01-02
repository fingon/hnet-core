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
-- Last modified: Wed Jan  2 11:39:16 2013 mstenber
-- Edit time:     360 min
--

-- This module contains the main mdns algorithm; it is not tied
-- directly to socket, event loop, or time functions. Instead,
-- bidirectional API is assumed to address those.

-- API from outside => mdns:

-- - run() - perform one iteration of whatever it does
-- - next_time() - when to run next time
-- - recvfrom(data, from, fromport)

-- additionally within mdns_ospf subclass
-- - skv 

-- API from mdns => outside:
-- - time() => current timestamp
-- - sendto(data, to, toport)

-- additionally within mdns_ospf subclass
--=> skv

-- Internally, implementation has two different data structures per if:

-- - cache (=what someone has sent to us, following the usual TTL rules)

-- - own (=what we want to publish on the link, following the state
--   machine for each record)

-- TODO: 

--  - deal with mdns + ospf-mdns skv stuff (rw)
--  ( perhaps treat them as interface that 'everyone' owns, and cache
--  = what we get from others, own = what we publish)

-- - active re-querying, perhaps, of things already seen? tie to ND?)

-- - spam limitations (how often each kind of RR can be transmitted on
--   a link, and even as response to a probe)

-- - noticing already sent responses on link (should be unlikely, but
--   you never know)

-- - filtering of RRs we pass along (linklocals aren't very useful,
--   for example)

require 'mst'
require 'dnscodec'
require 'dnsdb'

module(..., package.seeall)

MDNS_MULTICAST_ADDRESS='ff02::fb'
MDNS_PORT=5353

-- probing states (waiting to send message N)
STATE_P1='p1'
STATE_P2='p2'
STATE_P3='p3'
STATE_PW='pw'
-- => a1 if no replies

-- waiting to start probe again
-- STATE_WP1='wp1' 
-- as we treat failed probes 'definitely not our problem', there isn't
-- conflict here.. :-p

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
              --[STATE_WP1]={1000, 1000},
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
             --[STATE_WP1]=STATE_P1,
             [STATE_A1]=STATE_A2,
             [STATE_A2]=false,
             [STATE_D1]=STATE_D2,
}

-- when should we send announce-like message?
announce_states = {[STATE_A1]=true, [STATE_A2]=true}

-- when should we send probe-like message?
probe_states = {[STATE_P1]=true, [STATE_P2]=true, [STATE_P3]=true}


mdns = mst.create_class{class='mdns', 
                        time=os.time,
                        mandatory={'sendto'}}

function mdns:init()
   -- per-if ns of entries received from network
   self.if2cache = {}
   -- per-if ns of entries we want to publish to that particular network
   self.if2own = {}
   -- array of pending queries we haven't answered to, yet
   -- (time, delay, ifname, msg)
   self.queries = mst.set:new{}
end

function mdns:repr_data()
   return '?'
end

function mdns:run()
   local removed = {}

   -- iteratively run through the object states until all are waiting
   -- for some future timestamp
   while self:run_own_states() > 0 do end

   -- expire items
   self:expire_old()

   -- reply to queries
   local now = self.time()
   for i, qe in ipairs(self.queries:keys())
   do
      if qe[2] <= now
      then
         self:handle_delayed_multicast_reply(unpack(qe))
         self.queries:remove(qe)
      end
   end
end

function mdns:expire_old()
   local now = self.time()
   for ifname, ns in pairs(self.if2own)
   do
      local pending = {}
      for i, rr in ipairs(ns:values())
      do
         if rr.valid and rr.valid <= now
         then
            -- get rid of the entry
            if not rr.cache_flush
            then
               table.insert(pending, rr)
               rr.ttl = 0
            end
            ns:remove_rr(rr)
         end
      end
      if #pending > 0
      then
         self:d('sending ttl=0 for ifname/#pending', ifname, #pending)

         -- send per-interface 'these are gone' fyi messages
         local s = dnscodec.dns_message:encode{an=pending}
         local dst = MDNS_MULTICAST_ADDRESS .. '%' .. ifname
         self.sendto(s, dst, MDNS_PORT)
      end
   end
end

function mdns:should_run()
   local nt = self:next_time()
   if not nt then return end
   local now = self.time()
   return nt <= now
end


function mdns:run_own_states()
   local now = self.time()
   local c = 0
   mst.a(type(now) == 'number', now)
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

function mdns:msg_has_qu_qd(msg)
   for i, q in ipairs(msg.qd)
   do
      if q.qu then return true end
   end
end

function mdns:recvfrom(data, src, srcport)
   local l = mst.string_split(src, '%')
   mst.a(#l == 2, 'invalid src', src)
   local addr, ifname = unpack(l)
   local msg = dnscodec.dns_message:decode(data)

   if srcport ~= MDNS_PORT or self:msg_has_qu_qd(msg)
   then
      self:handle_unicast_query(msg, src, srcport)
      return
   end
   -- we don't care about srcport, as it's shared from now on.  let's
   -- just pass along ifname from now on, and we should be good (addr,
   -- while interesting, is not really needed)

   -- ok. it's qm message, but question is, what is it?
   -- cases we want to distinguish:

   -- a) probe (qd=query, ns=authoritative)
   if msg.qd and #msg.qd>0
   then
      if msg.ns and #msg.ns>0
      then
         self:handle_multicast_probe_ifname(msg, ifname)
         return
      end

      -- b) query (qd=query set [rest we ignore])
      self:handle_multicast_query_ifname(msg, ifname)
      return
   end

   -- c) response/announce (an=answer, ar=additional records)
   -- (announce is just unsolicited response)
   if msg.an and #msg.an>0
   then
      self:handle_multicast_response(msg, ifname)
      return
   end
end

function match_q_rr(q, rr)
   return (q.qtype == dnscodec.TYPE_ANY or q.qtype == rr.rtype) and
      (q.qclass == dnscodec.CLASS_ANY or q.qclass == rr.rclass) and
      (dnsdb.ll_equal(q.name, rr.name))
end

function mdns:find_if_own_matching_queries(ql, an, ifname)
   local r = mst.set:new{}
   local ns = self:get_if_own(ifname)

   for i, q in ipairs(ql)
   do
      for i, rr in ipairs(ns:find_rr_list_for_ll(q.name))
      do
         if match_q_rr(q, rr)
         then  
            -- XXX - this brute force checking is N^2 complexity
            -- (N matches, N KAS; could do better, but with higher
            -- startup costs, is it worth it? probably not)
            local found = false
            for i, rr2 in ipairs(an)
            do
               self:d('considering KAS', rr, rr2)
               if dnsdb.rr_equals(rr, rr2)
               then
                  self:d(' KAS match')
                  found = true
               end
            end
            if not found
            then
               r:insert(rr)
            end
         end
      end
   end
   return r:keys()
end

function mdns:copy_rrs_with_updated_ttl(rrl, unicast)
   local r = {}
   local now = self.time()
   for i, rr in ipairs(rrl)
   do
      self:a(rr.valid)
      local ttl = math.floor(rr.valid-now)
      if not unicast 
      then
         if rr.valid_to_send and rr.valid_to_send > now
         then
            ttl = 0
         elseif ttl > 0
         then
            -- mark when it can be sent again.. as this is the last point,
            -- it really goes off after this
            rr.valid_to_send = now + 1
         end
      end
      if ttl > 0
      then
         local n = mst.table_copy(rr)
         n.ttl = ttl
         table.insert(r, n)
      end
   end
   return r
end

function mdns:handle_reply(msg, dst, dstport, ifname, unicast)
   local an = self:find_if_own_matching_queries(msg.qd, msg.an, ifname)
   if #an == 0 then return end
   an = self:copy_rrs_with_updated_ttl(an, unicast)
   if #an == 0 then return end
   -- ok, we have valid things to send with >0 ttl; here we go!
   local s = dnscodec.dns_message:encode{an=an}
   self.sendto(s, dst, dstport)

end

function mdns:handle_unicast_query(msg, src, srcport)
   self:d('handle_unicast_query', src, srcport)
   -- given the 'own' data on interface, use that (and only that) to reply
   -- if nothing to reply, do not retry at all!
   
   -- no rate limiting or anything here, we just brutally reply whenever
   -- someone unicasts us (we're nice like that)
   local l = mst.string_split(src, '%')
   mst.a(#l == 2, 'invalid src', src)
   local addr, ifname = unpack(l)

   self:handle_reply(msg, src, srcport, ifname, true)
end

function mdns:handle_delayed_multicast_reply(t, when, ifname, msg)
   local now = self.time()
   self:d('handle_delayed_multicast_reply', t, when, now, ifname)
   local dst = MDNS_MULTICAST_ADDRESS .. '%' .. ifname
   self:handle_reply(msg, dst, MDNS_PORT, ifname, false)
end

function mdns:handle_multicast_probe_ifname(msg, ifname)
   self:d('got probe', ifname)
   -- zap _all_ records matching the entries being probed
   -- (this way, we don't really need to care about the resolution, and
   -- once the rr gets announced (or has conflict with someone else),
   -- it's not OUR problem)
   for i, rr in ipairs(msg.ns)
   do
      if rr.cache_flush
      then
         self:remove_rr_ifs_own(rr, true)
      end
   end
end

function mdns:handle_multicast_query_ifname(msg, ifname)
   -- we can safely delay non-probe answers always
   -- (although it would be nice to be more defensive)
   local now = self.time()
   local when = now+mst.randint(20, 120)/1000.0
   self:d('queueing reply', now, when)
   self.queries:insert{now, when, ifname, msg}
end

function mdns:update_rr_ttl(o, ttl, update_field)
   o.ttl = ttl
   o.time = self.time()
   o.valid = o.time + o.ttl
   if update_field
   then
      o[update_field] = o.time
   end
end

function mdns:handle_rr_cache_update(rr, ifname)
   local ns = self:get_if_cache(ifname)
   local old_rr = ns:find_rr(rr)
   local o

   if rr.cache_flush
   then
      -- stop publishing potentially conflicting ones _everywhere_
      -- (= different from the 'rr' - 'rr' itself is ok)
      self:remove_rr_ifs_own(rr, true)
   end
   if old_rr
   then
      if dnsdb.rr_equals(old_rr, rr)
      then
         o = old_rr
         -- yay, all we need to do is just update ttl
         self:update_rr_ttl(o, rr.ttl, true)
      end
   end
   -- insert_rr if we don't have valid o yet
   if not o 
   then 
      -- if we didn't announce it, no need to start with 0 announce
      if rr.ttl == 0 then return end
      o = ns:insert_rr(rr) 
   end
   -- if information conflicts, don't propagate it
   -- (but instead remove everything we have)
   if self:rr_has_conflicts(o)
   then
      self:remove_rr_ifs_own(rr)
      return
   end
   -- propagate the information (in some form) onwards
   self:propagate_rr_from_if(o, ifname)
end

function mdns:remove_rr_ifs_own(rr, eliminate_exact_matches)
   -- remove all matching _own_ rr's
   -- (we simply pretend rr doesn't exist at all)
   for ifname, ns in pairs(self.if2own)
   do
      for i, rr2 in ipairs(ns:find_rr_list_for_ll(rr.name))
      do
         if rr.rtype == rr2.rtype and dnsdb.rr_contains(rr2, rr) and not dnsdb.rr_equals(rr2, rr)
         then
            ns:remove_rr(rr2)
         end
      end
   end
end

function mdns:handle_rr_list_cache_update(rrlist, ifname)
   if not rrlist or not #rrlist then return end
   for i, rr in ipairs(rrlist)
   do
      self:handle_rr_cache_update(rr, ifname)
   end
end

function mdns:handle_multicast_response(msg, ifname)
   self:d('got response', ifname)

   -- grab more information from an/ar - it's hopefully valid!
   self:handle_rr_list_cache_update(msg.an, ifname)
   self:handle_rr_list_cache_update(msg.ar, ifname)
end

function mdns:handle_unicast_reply(msg, src, srcport)
   
end

function mdns:rr_has_conflicts(rr)
   -- if it's non-cache-flush-entry, it's probably ok
   -- XXX - what should be the behavior be with mixed unique/shared
   -- entries for same names?
   if not rr.cache_flush
   then
      return
   end

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
         if o.rtype == rr.rtype and dnsdb.rr_contains(o, rr) and not dnsdb.rr_equals(rr, o)
         then
            self:d('found conflict for ', rr, o)
            return true
         end
      end
   end
end

function mdns:insert_if_own_rr(ifname, rr)
   local ns = self:get_if_own(ifname)
   -- XXX - do something with the old?
   --local old_rr = ns:find_rr(rr)
   if rr.ttl == 0
   then
      -- don't do a thing if it doesn't exist
      local o = ns:find_rr(rr)
      if not o
      then
         return 
      end
   end
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
   self:update_rr_ttl(o, rr.ttl)
   return o
end

function mdns:set_state(ifname, rr, st)
   local w = STATE_DELAYS[st]
   self:d('setting state', rr, st)
   rr.state = st
   if w
   then
      local now = self.time()
      mst.a(type(now) == 'number', 'wierd time', now)
      rr.wait_until = now + mst.randint(w[1], w[2]) / 1000.0
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

function mdns:next_time()
   local best = nil
   function maybe(t)
      if not t then return end
      if not best or t < best
      then
         best = t
      end
   end

   for ifname, ns in pairs(self.if2own)
   do
      local pending = {}
      for i, rr in ipairs(ns:values())
      do
         if rr.state
         then
            maybe(rr.wait_until)
         end
         maybe(rr.valid)
      end
   end
   for i, e in ipairs(self.queries)
   do
      maybe(e[2])
   end
   return best
end

function mdns:send_announces(ifname)
   -- try to send _all_ eligible announcements at once.
   -- e.g. entries that are in one of the send-announce states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self:get_if_own(ifname)
   local an = {}
   local now = self.time()
   for i, rr in ipairs(ns:values())
   do
      if announce_states[rr.state] and not rr.wait_until
      then
         -- xxx - do something more clever here?
         table.insert(an, rr)

         self:set_next_state(ifname, rr)
         rr.valid_to_send = now + 1
      end
   end
   -- XXX ( handle fragmentation )
   if #an > 0
   then
      local s = dnscodec.dns_message:encode{an=an}
      local dst = MDNS_MULTICAST_ADDRESS .. '%' .. ifname
      self.sendto(s, dst, MDNS_PORT)
   end
end

function mdns:send_probes(ifname)
   -- try to send _all_ eligible probes at once.
   -- e.g. entries that are in one of the send-probe states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self:get_if_own(ifname)
   local qd = {}
   local ons = {}
   for i, rr in ipairs(ns:values())
   do
      if probe_states[rr.state] and not rr.wait_until
      then
         table.insert(qd, {qtype=rr.rtype,
                           qclass=rr.rclass,
                           name=rr.name})
         table.insert(ons, rr)

         self:set_next_state(ifname, rr)
      end
   end
   -- XXX ( handle fragmentation )
   if #qd > 0
   then
      local s = dnscodec.dns_message:encode{qd=qd, ns=ons}
      local dst = MDNS_MULTICAST_ADDRESS .. '%' .. ifname
      self.sendto(s, dst, MDNS_PORT)
   end
end


function mdns:propagate_rr_from_if(rr, ifname)
   -- child responsibility, by default we don't propagate anything
   error("child responsibility - propagate_rr_from_if")
end
