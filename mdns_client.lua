#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_client.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May  9 12:26:36 2013 mstenber
-- Last modified: Thu Jul 18 15:51:42 2013 mstenber
-- Edit time:     120 min
--

-- This is purely read-only version of mdns code. It leverages
-- mdns_core (and therefore mdns_if), but it does not attempt to
-- propagate any information whatsoever. This is done adding NOP
-- queue_check_propagate_if_rr in the mdns_client class.

-- Instead, ~synchronous (see scr.lua) interface using coroutines is
-- provided, which under the hood maps to mdns_client running within
-- ssloop, and it's results being polled every now and then.

-- Events are used to notice when something related to request _might_
-- be available (and then to do more heavy processing).

-- Assumptions:
--
-- If there's something in cache with CF set, it is the truth and
-- whole truth => We can return that immediately.
--
-- Otherwise, schedule a query, wait until either we get something
-- with CF set (=> respond 'immediately'), or until we time out (0,8
-- seconds). This figure is chosen so that e.g. Windows naming
-- resolution won't give up - it has 1 second timeout for first try.
--
-- => We should provide _something_ for CF records almost immediately,
-- and for non-CF, we have sub-second delay. Tough. (Given LLQ enabled
-- client, we could do this also faster, but we don't currently have
-- any way to make sure of that.)

require 'mst'
require 'mdns_core'
require 'scr'
local _eventful = require 'mst_eventful'.eventful
local _mdns = mdns_core.mdns

module(..., package.seeall)

mdns_client_request = _eventful:new_subclass{class='mdns_client_request',
                                             mandatory={'ifo', 'q'}}

function mdns_client_request:init()
   -- superclass init
   _eventful.init(self)
   
   -- hook up to ifo cache change notification stuff; inserted
   -- cache_flush rr's interest us greatly
   self:connect_method(self.ifo.cache.inserted, 
                       self.inserted_cache_rr)

   -- start query
   self.ifo:query(self.q)
   
   -- store the objects for later use
   self.t, self.to = scr.get_timeout(self.timeout)

   self:d('init done')

end

function mdns_client_request:uninit()
   if self.to
   then
      self.to:done()
   end

   -- superclass uninit
   _eventful.uninit(self)

   self:d('uninit done')
end

function mdns_client_request:repr_data()
   return mst.repr{
      ifo=self.ifo,
      q=self.q,
      timeout=self.timeout,
                  }
end

function mdns_client_request:inserted_cache_rr(rr)
   if rr.cache_flush
   then
      self:d('inserted_cache_rr (cf)')
      self.had_cf = true
   else
      self:d('inserted_cache_rr (non-cf)')
   end
end

function mdns_client_request:wait_done()
   local had_cf = function ()
      return self.had_cf
   end
   coroutine.yield(had_cf, self.t)
end

function mdns_client_request:is_done()
   return self.had_cf or self.had_timeout
end

mdns_client = _mdns:new_subclass{class='mdns_client'}

function mdns_client:init()
   _mdns.init(self)
   self.requests = mst.set:new{}
end

function mdns_client:uninit()
   for r, _ in pairs(self.requests)
   do
      r:done()
   end
   _mdns.uninit(self)
end


function mdns_client:resolve_ifo_q(ifo, q, cache_flush)
   local r
   self:d('resolve_ifo_q', ifo, q, cache_flush)
   -- check own
   ifo:iterate_matching_query(true,
                              q,
                              nil,
                              function (rr)
                                 self:d(' found own', rr)
                                 if not cache_flush or rr.cache_flush
                                 then
                                    r = r or {}
                                    table.insert(r, rr)
                                 end
                              end)
   -- check cache
   ifo:iterate_matching_query(false,
                              q,
                              nil,
                              function (rr)
                                 self:d(' found cache', rr)
                                 if not cache_flush or rr.cache_flush
                                 then
                                    r = r or {}
                                    table.insert(r, rr)
                                 end
                              end)
   if r
   then
      -- refresh TTLs
      r = ifo:copy_rrs_with_updated_ttl(r, true)
      -- if none of them were valid, return nil
      -- (copy_rrs_with_updated_ttl returns empty list in that case)
      if #r == 0
      then
         return
      end
   end
   return r
end

function mdns_client:queue_check_propagate_if_rr(ifname, rr)
   -- we never propagate anything - pure resolver only
   return
end

function mdns_client:run_request(ifo, q, timeout)
   for r, _ in pairs(self.requests)
   do
      if mst.repr_equal(q, r.q) and ifo == r.ifo and timeout == r.timeout
      then
         -- yay, let's just latch on to this!
         r:wait_done()
         return r.had_cf
      end
   end
   -- nothing readily available => have to create new request
   local o = mdns_client_request:new{ifo=ifo, q=q, timeout=timeout}
   self:d('start request', o)
   self.requests:insert(o)
   o:wait_done()
   o:done()
   self.requests:remove(o)
   self:d('end request', o, mst.table_count(self.requests))
   return o.had_cf
end

function mdns_client:resolve_ifname_q(ifname, q, timeout)
   self:d('resolve_ifname_q', ifname, q, timeout)
   local ifo = self:get_if(ifname)
   
   -- immediately check if we have something with cf set true
   local r = self:resolve_ifo_q(ifo, q, true)
   if r
   then
      self:d(' immediate', r)
      return r, true
   end

   -- no such luck, we have to play with mdns_client_request, and wait
   -- up to timeout (or cf entry). in truth, we actually may wait for
   -- earlier request started by someone else to complete.
   local had_cf = self:run_request(ifo, q, timeout)

   -- now, just dump whatever we have in cache (if anything) as result
   self:d('wait finished, checking cache')

   r = self:resolve_ifo_q(ifo, q)
   self:d('found in cache', r)

   return r or {}, had_cf
end

function mdns_client:update_own_records_if(myname, ns, o, rrs, rtype)
   self:d('update_own_records_own_o_rrs', o, rrs)

   -- remove old records if any
   if self.myname and self.myname ~= myname
   then
      -- name changed => have to zap
      -- (using old name)
      local fo = {name={self.myname, 'local'}, rtype=rtype, cache_flush=true}
      o:propagate_o_l(fo, nil, true)
   end

   -- Ok, perhaps the records changed, perhaps not
   -- (using new name)
   local fo = {name={myname, 'local'}, rtype=rtype, cache_flush=true}
   o:propagate_o_l(fo, rrs, true)
end

function mdns_client:get_a_addrs(map)
   local addrs = {}
   for ifname, o in pairs(map)
   do
      local found
      local addr = o.ipv4
      if addr
      then
         -- eliminate /x
         addr = mst.string_split(addr, '/')[1]

         addrs[addr] = true
         -- if we have address on device, we _should_ care about it
         -- enough to have own data structure for it too. this should
         -- make sure of that.
         self:d('found v4', addr, ifname)
         self:get_if(ifname)
      end
   end
   return addrs
end


function mdns_client:get_aaaa_addrs(map)
   local addrs = {}

   -- create forward name record list. for inverse direction, stuff
   -- happens 'underneath' (in if-specific propagate_o_l)
   local rrs = mst.array:new{}
   for ifname, o in pairs(map)
   do
      local found
      for i, addr in ipairs(o.ipv6)
      do
         found = true

         -- eliminate /64
         addr = mst.string_split(addr, '/')[1]
         addrs[addr] = true
         self:d('found v6', addr, ifname)
      end

      if found
      then
         -- if we have address on device, we _should_ care about it
         -- enough to have own data structure for it too. this should
         -- make sure of that.
         self:get_if(ifname)
      end
   end

   return addrs
end

function mdns_client:addrs_to_rrs(myname, rtype, addrs)
   local rrs = mst.array:new{}
   local m = dns_rdata.rtype_map[rtype]
   local addrfield = m.field
   for addr, _ in pairs(addrs)
   do
      rrs:insert{name={myname, 'local'},
                 rclass=dns_const.CLASS_IN,
                 rtype=rtype,
                 [addrfield]=addr,
                 cache_flush=true,
                }
   end
   return rrs
end

function mdns_client:update_own_records_addrs(myname, rtype, addrs)
   self.rtype2addr = self.rtyp2addr or {}
   -- if no change, just don't do a thing
   if mst.repr_equal(self.rtype2addr[rtype], addrs) and myname == self.myname
   then
      return
   end
   self.rtype2addr[rtype] = addrs
   local rrs = self:addrs_to_rrs(myname, rtype, addrs)
   self:iterate_ifs_ns(true, function (ns, o)
                          self:update_own_records_if(myname, ns, o, rrs,
                                                     rtype)
                             end)
   
end

function mdns_client:update_own_records(myname)
   -- without name, there is no point
   if not myname
   then
      self:a(not self.myname, 'had name but it was lost?')
      return
   end

   local map4, gen4 = self:get_ipv4_map()
   local map6, gen6 = self:get_ipv6_map()

   -- force refresh
   if myname ~= self.myname
   then
      self.gen4 = nil
      self.gen6 = nil
   end

   -- nothing changed, nop
   if gen4 == self.gen4 and gen6 == self.gen6
   then
      return
   end

   self:d('update_own_records', myname, self.myname, map6)

   if gen4 ~= self.gen4
   then
      local m = self:get_a_addrs(map4)
      self:update_own_records_addrs(myname, dns_const.TYPE_A, m)
      self.gen4 = gen4
   end

   if gen6 ~= self.gen6
   then
      local m = self:get_aaaa_addrs(map6)
      self:update_own_records_addrs(myname, dns_const.TYPE_AAAA, m)
      self.gen6 = gen6
   end

   self.myname = myname
end

function mdns_client:update_own_records_from_ospf_lap(myname, lapl)
   self:d('update_own_records_from_ospf_lap')
   -- if we don't know things, yet, let's wait until we do
   if not myname or not lapl
   then
      self:d(' no myname/lapl', myname, lapl)
      return
   end
   -- this is unconditional; we do it always (hopefully we KNOW when
   -- the lap changes)
   local function _get_map(is_ipv4)
      local m = {}
      for i, lap in ipairs(lapl)
      do
         local addr = lap.address
         if addr and not lap.dep and not lap.external
         then
            if not ipv6s.address_is_ipv4(addr) == not is_ipv4
            then
               self:d(' ', addr)
               m[addr] = true
               self:get_if(lap.ifname)
            end
         end
      end
      return m
   end
   local m = _get_map(true)
   self:update_own_records_addrs(myname, dns_const.TYPE_A, m)

   local m = _get_map(false)
   self:update_own_records_addrs(myname, dns_const.TYPE_AAAA, m)
end
