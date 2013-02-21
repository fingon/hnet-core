#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_ospf.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Jan  2 11:20:29 2013 mstenber
-- Last modified: Thu Feb 21 11:55:52 2013 mstenber
-- Edit time:     266 min
--

-- This is mdns proxy implementation which uses OSPF for state
-- synchronization. In practise, the 'skv' field of mdns_ospf is used
-- for bidirectional passing of data to the OSPF.

-- outside => mdns
--    ospf-lap ( to check if owner, or not )
--    ospf-mdns = {} 

-- mdns => outside
--    mdns = {}

-- ospf-mdns, and mdns contain entries with {name={'x','y','z'},
-- rtype=N, rdata_N='...'} format. Omitted things: 

-- - ttl (we use mdns defaults, as stuff in OSPF is 'valid for now',
-- and once it disappears from OSPF, it should also disappear from
-- hosts)

-- - rdata_N is human readable rtype-specific version (mostly for
-- debugging purposes for now; it could be also raw rdata )

-- Most of the heavy lifting is done by the mdns_{core,if}; they
-- provide basic mdns abstraction, and all we do is just customize
-- those classes to our needs by subclassing. Namely, 

-- mdns_if is subclassed so that we're interested in refreshing cache
-- validity times if and only if we're owner for that interface
-- according to OSPF, and to get notifications whenever contents of
-- cache have changed (in terms of rr's having been added or removed)

-- mdns_core subclassing is to just to package the skv listening stuff
-- which does others => us propagation, as well as our caches => ospf
-- state transfer.


require 'mdns_core'
require 'mdns_if'
require 'elsa_pa'

module(..., package.seeall)

-- this results in more efficient encoding, and better human
-- readability, where applicable
USE_STRINGS_INSTEAD_OF_NAMES_IN_SKV=true

local _mdns_if = mdns_if.mdns_if
local _mdns = mdns_core.mdns

ospf_if = _mdns_if:new_subclass{class='ospf_if'}

-- by default, OSPF based interfaces are interested in EVERYTHING, 
-- as long as they're master
function ospf_if:interested_in_cached(rr)
   -- if not master, not interested (unless there's ongoing continuous query)
   if not self.parent.master_if_set[self.ifname] 
   then 
      return _mdns_if.interested_in_cached(self, rr)
   end
   -- if master, yes, we're interested
   self:d('master interface, interested in cached', rr)
   return mdns_if.q_for_rr(rr)
end

function ospf_if:cache_changed_rr(rr, mode)
   self.parent.cache_dirty = true
   _mdns_if.cache_changed_rr(self, rr, mode)
end

mdns = _mdns:new_subclass{class='mdns_ospf',
                          ifclass=ospf_if,
                          mandatory={'sendto', 'skv'}}

function mdns:valid_propagate_src_ifo(ifo)
   -- nil ifo == OSPF cache, it is certainly valid
   if not ifo
   then
      return true
   end
   return self.master_if_set[ifo.ifname]
end

function mdns:valid_propagate_dst_ifo(ifo)
   return self.master_if_set[ifo.ifname]
end


function mdns:init()
   -- by default, no master if's
   self.master_if_set = mst.set:new{}

   _mdns.init(self)
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
   self.ospf_cache_ns = dnsdb.ns:new{}
end

function mdns:kv_changed(k, v)
   if k == elsa_pa.OSPF_LAP_KEY
   then
      self:d('queueing lap update')
      self.ospf_lap = v
      self.update_lap = true
      -- force recalculation of 'local prefix' data
      self.local_binary2ifname_refresh = nil
   end
   if k == elsa_pa.MDNS_OSPF_SKV_KEY
   then
      self:d('ospf-cache updated', #v)
      self.ospf_skv = v
      self.update_ospf = true
   end
end

function mdns:uninit()
   self.skv:remove_change_observer(self.f)
end


function mdns:calculate_local_binary_prefix_set()
   local m = {}
   for i, lap in ipairs(self.ospf_lap or {})
   do
      local p = ipv6s.new_prefix_from_ascii(lap.prefix)
      if not p:is_ipv4()
      then
         local dep = lap.depracate      
         local own = lap.owner 
         local ext = lap.external
         -- XXX - figure what's relevant - for time being, let's do non-ext?
         if not ext
         then
            m[p:get_binary()] = lap.ifname
         end
      end
   end
   return m
end

function mdns:handle_ospf_cache()
   -- OSPF cache contents changed. Two cases that we care about, per rr.
   -- a)
   --  rr was added
   -- b)
   --  rr was removed
   --
   -- To make this check relatively efficient, we keep dnsdb.ns of
   -- our own just for storing the ospf cache state
   -- (self.ospf_cache_ns), and sync ospf_skv with that


   -- ospf cache contents
   local ns = self.ospf_cache_ns

   -- invalidate the ns contents
   ns:iterate_rrs(function (rr) rr.invalid = true end)

   local l = self.ospf_skv
   self:d('refreshing from ospf-cache', #l)

   -- first, handle existing ones (call propagate, whatever it does
   -- for them..)
   for i, rr in ipairs(l)
   do
      -- convert the (potentially string name) to list of domains
      rr.name = dnsdb.name2ll(rr.name)

      local orr = ns:find_rr(rr)
      if orr
      then
         orr.invalid = nil
         self:handle_ospf_updated_rr(rr)
      else
         rr = ns:insert_rr(rr, true)
         self:handle_ospf_added_rr(rr)
      end
   end
   
   -- then, look for invalid ones
   ns:iterate_rrs_safe(function (rr)
                          if not rr.invalid then return end
                          self:handle_ospf_removed_rr(rr)
                          ns:remove_rr(rr)
                       end)
end

function mdns:iterate_ifs_ns(is_own, f)
   if not is_own
   then
      f(self.ospf_cache_ns)
   end
   _mdns.iterate_ifs_ns(self, is_own, f)
end

function mdns:handle_ospf_added_rr(rr)
   self:queue_check_propagate_if_rr(nil, rr)
end

function mdns:handle_ospf_updated_rr(rr)
   self:queue_check_propagate_if_rr(nil, rr)
end

function mdns:handle_ospf_removed_rr(rr)
   self:d('setting ttl=0', rr)
   -- wtf should we do with this anyway? update with
   -- ttl=0, and then get rid of it?
   rr.ttl = 0

   -- get rid of every rr that is exactly like this
   self:iterate_ifs_ns(true, function (ns, ifo)
                          local orr = ns:find_rr(rr)
                          if orr
                          then
                             ifo:start_expire_own_rr(orr)
                          end
                             end)
   
   self:queue_check_propagate_if_rr(nil, rr)
end



function mdns:run()
   if self.update_lap
   then
      self.update_lap = nil

      self:d('running lap update')

      self:set_if_master_set(self:calculate_if_master_set())
   end
   if self.update_ospf
   then
      self.update_ospf = nil
      self:handle_ospf_cache()
   end
   if self.cache_dirty
   then
      -- publish all owned interfaces' caches to skv
      self.cache_dirty = false

      self:publish_cache()
   end
   return _mdns.run(self)
end

function mdns:reduce_ns_to_nondangling_array(ns)
   local a = mst.array:new{}
   local ok = mst.set:new{} -- names that are 'ok'
   local pending = mst.multimap:new{} -- pending entries

   -- forward decl
   local process

   local function add_to_ok(k)
      if ok[k]
      then
         return
      end
      ok:insert(k)
      while pending[k] and #pending[k] > 0
      do
         local v = pending[k][1]
         pending:remove(k, v)
         process(v)
      end
   end

   local function depend(rr, n)
      local kv = dnsdb.ll2key(n)
      if not ok[kv]
      then
         -- add to pending
         pending:insert(kv, rr)
         return
      end
      -- yay, it is already covered target -> we can note that this
      -- name is ok too
      local k = dnsdb.ll2key(rr.name)
      add_to_ok(k)
      return true
   end

   function process(rr)
      self:a(type(rr) == 'table', 'weird rr', rr)
      if rr.rtype == dns_const.TYPE_AAAA
      then
         local k = dnsdb.ll2key(rr.name)
         add_to_ok(k)
      elseif rr.rtype == dns_const.TYPE_SRV
      then
         if not depend(rr, rr.rdata_srv.target) then return end
      elseif rr.rtype == dns_const.TYPE_PTR
      then
         if not depend(rr, rr.rdata_ptr) then return end
      end

      a:insert(rr)
   end

   ns:iterate_rrs(process)

   return a
end

function mdns:publish_cache()
   -- gather the rr's in dnsdb.ns, to prevent duplicates from hitting
   -- the wire
   local ns = dnsdb.ns:new{}
   
   for ifname, ifo in pairs(self.ifname2if)
   do
      -- we care only about owned interfaces - rest can be ignored safely
      if self.master_if_set[ifname]
      then
         ifo.cache:iterate_rrs(function (rr)
                                  if not self:is_forwardable_rr(rr)
                                  then
                                     return
                                  end
                                  ns:insert_rr(rr)
                               end)
      end
   end

   local t = self:reduce_ns_to_nondangling_array(ns)

   -- then, convert the raw cached rr's to simpler structure we want
   -- to stick in skv
   t = t:map(function (rr)
                local rt = rr.rtype
                local to = dns_rdata.rtype_map[rt]
                local f = (to and to.field) or 'rdata'
                local v = rr[f]
                self:a(v, 'no rdata?', to, rr)
                local n = USE_STRINGS_INSTEAD_OF_NAMES_IN_SKV and dnsdb.ll2nameish(rr.name) or rr.name
                -- if 'false', don't include it at all
                local cf = rr.cache_flush and rr.cache_flush or nil
                local d = {name=n,
                           rtype=rt,
                           rclass=rr.rclass,
                           cache_flush=cf,
                           [f]=v,
                }
                mst.d(' adding entry', d)
                return d
             end)

   self:d('publishing cache', #t)
   self.skv:set(elsa_pa.MDNS_OWN_SKV_KEY, t)

end

function mdns:ospf_should_run()
   return self.update_lap or self.cache_dirty or self.update_ospf
end

function mdns:should_run()
   if self:ospf_should_run() then return true end
   return _mdns.should_run(self)
end

function mdns:next_time()
   if self:ospf_should_run() then return 0 end
   return _mdns.next_time(self)
end

function mdns:calculate_if_master_set()
   local t = mst.set:new{}
   local shouldjoin = mst.set:new()
   -- for rest, we look at the SKV-LAP for stuff that we own, and that
   -- isn't depracated or external
   for i, lap in ipairs(self.ospf_lap)
   do
      local dep = lap.depracate      
      local own = lap.owner 
      local ext = lap.external
      if not dep and not ext
      then
         if own
         then
            t:insert(lap.ifname)
         end
         -- either way, we're interested about this interface - make
         -- sure we're joined to multicast group for it
         shouldjoin[lap.ifname] = true
      end
   end
   self:set_if_joined_set(shouldjoin)
   return t
end

function mdns:set_if_master_set(masterset)
   self.master_if_set = masterset
   local fresh
   self:d('syncing ifs', masterset)
   local state_changed
   mst.sync_tables(self.ifname2if, self.master_if_set,
                   -- remove spurious
                   function (k, v)
                      if not v.is_master then return end
                      self:d(' removing ', k)
                      state_changed = true
                      v.is_master = nil
                   end,
                   -- add missing
                   function (k, v)
                      self:d(' adding ', k)
                      local o = self:get_if(k)
                      state_changed = true
                      o.is_master = true
                   end,
                   -- non-master if isn't _really_ the same,
                   -- but we convert it to master one and just
                   -- put it on fresh list to do new propagation
                   -- there (this is bit of a kludge, but oh well)
                   function (k, v1, v2)
                      if not v1.is_master 
                      then
                         self:d(' enabling ', k)
                         v1.is_master = true
                         state_changed = true
                      end
                      return true
                   end
                  )
   -- brute-force solution
   if state_changed
   then
      self:d('master set changed, scheduling full propagation')
      self:queue_check_propagate_all()
      self:run_propagate_check()
   end
end

function mdns:propagate_rr_to_ifo(rr, ifo)
   -- if we have received the entry _from_ that interface,
   -- we don't want to propagate it there
   local nsc = ifo.cache
   if not nsc:find_rr(rr)
   then
      -- there isn't conflict - so we can just peacefully insert
      -- the rr to the own list
      self:d('adding to', ifo)
      ifo:insert_own_rr(rr)
   else
      self:d('in cache of interface', ifo)

   end
end

function mdns:propagate_if_rr(ifname, rr)
   -- if we're not 'master' for that if, ignore it
   if ifname and not self.master_if_set[ifname] then return end

   for toif, _ in pairs(self.master_if_set)
   do
      if toif ~= ifname
      then
         local ifo = self:get_if(toif)
         self:propagate_rr_to_ifo(rr, ifo)
      end
   end
end

