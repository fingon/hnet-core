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
-- Last modified: Mon Nov  4 14:08:34 2013 mstenber
-- Edit time:     994 min
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

-- - noticing already sent responses on link (should be unlikely, but
--   you never know)

-- - filtering of RRs we pass along (linklocals aren't very useful,
--   for example)

-- - ton more, see SHOULD/MUST list in mdns_test.txt

require 'mst'
require 'dns_db'
require 'mdns_if'
require 'mdns_const'
require 'linux_if'
require 'ssloop'
local _mcj = require 'mcastjoiner'.mcj
local _eventful = require 'mst_eventful'.eventful

IF_INFO_VALIDITY_PERIOD=60

module(..., package.seeall)

-- global mdns structure, which mostly just deals with different
-- mdns_if instances
mdns = mst.create_class({class='mdns', 
                         ifclass=mdns_if.mdns_if,
                         time=ssloop.time,
                         mandatory={'sendto', 'shell'},
                         events={'if_active'}, -- ifname + true/false
                        },
                        _mcj,
                        _eventful)

function mdns:init()
   _mcj.init(self)
   _eventful.init(self)
   self.ifname2if = {}
end

function mdns:uninit()
   -- intentionally not calling _mcj.uninit 
   -- (it would try to detach skv, while not attached - we play with
   -- skv from superclass, not in mcj)
   _eventful.uninit(self)

   -- call uninit for each interface object (intentionally after us,
   -- as we are connected _to_ interface object)

   for ifname, ifo in pairs(self.ifname2if)
   do
      ifo:done()
   end

end

function mdns:get_ipv4_map()
   local now = self.time()
   local was = self.ipv4map_refresh
   local refreshed
   if not was or (was + IF_INFO_VALIDITY_PERIOD) < now
   then
      -- TODO - consider if it is worth storing this if_table;
      -- for the time being, we save memory by not keeping it around..
      local if_table = linux_if.if_table:new{shell=self.shell} 
      self.ipv4map = if_table:read_ip_ipv4()
      self.ipv4map_refresh = now
   end
   return self.ipv4map, self.ipv4map_refresh
end

function mdns:get_ipv6_map()
   local now = self.time()
   local was = self.ipv6map_refresh
   local refreshed
   if not was or (was + IF_INFO_VALIDITY_PERIOD) < now
   then
      -- TODO - consider if it is worth storing this if_table;
      -- for the time being, we save memory by not keeping it around..
      local if_table = linux_if.if_table:new{shell=self.shell} 
      self.ipv6map = if_table:read_ip_ipv6()
      self.ipv6map_refresh = now
   end
   return self.ipv6map, self.ipv6map_refresh
end

function mdns:calculate_local_binary_prefix_set()
   local map = self:get_ipv6_map()
   local m = {}
   for ifname, ifo in pairs(map)
   do
      for i, prefix in ipairs(ifo.ipv6 or {})
      do
         local p = ipv6s.new_prefix_from_ascii(prefix)
         local b = p:get_binary()
         local v = m[b]
         -- intentionally produce always consistent mapping to interfaces
         -- here - that's why we do this check
         if not v or v > ifname
         then
            m[b] = ifname
         end
      end
   end
   return m
end

function mdns:get_local_binary_prefix_set()
   local map, gen = self:get_ipv6_map()
   if gen ~= self.local_binary2ifname_gen
   then
      local m = self:calculate_local_binary_prefix_set()
      self.local_binary2ifname = m
      self.local_binary2ifname_gen = gen
   end
   self:a(self.local_binary2ifname, 
          'no local_binary2ifname', 
          map, gen)
   return self.local_binary2ifname
end

function mdns:is_local_binary_prefix(b)
   return self:get_local_binary_prefix_set()[b]
end

function mdns:get_local_interface(addr)
   -- it better be IPv6; IPv4 we don't care about for the time being
   local r = ipv4s.address_to_binary_address(addr)
   if r
   then
      return
   end

   -- ok, looks like IPv6 address
   local b = ipv6s.address_to_binary_address(addr)
   mst.a(#b == 16)

   -- just use the prefix as key
   b = string.sub(b, 1, 8)

   return self:is_local_binary_prefix(b)
end

function mdns:get_if(ifname)
   mst.a(type(ifname) == 'string', 'non-string ifname', ifname)
   local o = self.ifname2if[ifname]
   if not o
   then
      o = self.ifclass:new{ifname=ifname, parent=self}
      self.ifname2if[ifname] = o
      self:connect(o.queue_check_propagate_rr,
                   function (rr)
                      self:queue_check_propagate_if_rr(ifname, rr)
                   end)
      self:connect(o.cache.is_not_empty,
                   function ()
                      self.if_active(ifname, true)
                   end)
      self:connect(o.cache.is_empty,
                   function ()
                      self.if_active(ifname, false)
                   end)
   end
   return o
end

function mdns:iterate_ifs_ns(is_own, f)
   self:a(f, 'nil function')
   for ifname, o in pairs(self.ifname2if)
   do
      local ns = is_own and o.own or o.cache
      f(ns, o)
   end
end

function mdns:iterate_ifs_matching_q(is_own, q, f)
   for ifname, o in pairs(self.ifname2if)
   do
      -- nil = no kas
      o:iterate_matching_query(is_own, q, nil, f)
   end
end

function mdns:repr_data()
   return mst.repr{rid=self.rid}
end

function mdns:run()
   self:run_propagate_check()
   self.now = self.time()
   -- expire items
   for ifname, ifo in pairs(self.ifname2if)
   do
      ifo:run()
   end
   self.now = nil
end

function mdns:should_run()
   local nt = self:next_time()
   if not nt then return end
   local now = self.time()
   return nt <= now
end

function mdns:next_time()
   local best
   if self.pending_propagate_check
   then
      best = 0
   else
      for ifname, ifo in pairs(self.ifname2if)
      do
         local b = ifo:next_time()
         if not best or (b and b < best)
         then
            best = b
         end
      end
   end
   mst.d('next_time returning', best)
   return best
end

function mdns:recvfrom(data, src, srcport)
   self:a(type(data) == 'string', 'non-string data', 
          data, src, srcport)

   self:a(type(src) == 'string', 'non-string src', 
          data, src, srcport)

   -- n/a - comes actually as a string, sigh
   --self:a(type(srcport) == 'number', 'non-number srcport', data, src, srcport)

   local l = mst.string_split(src, '%')
   local addr, ifname
   if #l < 2 
   then
      addr = src
      ifname = self:get_local_interface(src)
      if not ifname
      then
         self:d('global? query received, ignoring', src)
         return
      end
   else
      mst.a(#l == 2, 'invalid src', src)
      addr, ifname = unpack(l)
   end

   local ifo = self:get_if(ifname)

   ifo:handle_recvfrom(data, addr, srcport)
end

local function nsh_count(nsh)
   mst.a(nsh)
   local c = 0
   for k, ns in pairs(nsh)
   do
      c = c + ns:count()
   end
   return c
end

function mdns:own_count()
   local c = 0
   self:iterate_ifs_ns(true, 
                       function (ns)
                          c = c + ns:count()
                       end)
   return c
end

function mdns:cache_count()
   local c = 0
   self:iterate_ifs_ns(false, 
                       function (ns)
                          c = c + ns:count()
                       end)
   return c
end

-- related things

function mdns:query(ifname, ...)
   local ifo = self:get_if(ifname)
   ifo:query(...)
end

function mdns:start_query(ifname, ...)
   local ifo = self:get_if(ifname)
   ifo:start_query(...)
end

function mdns:stop_query(ifname, ...)
   local ifo = self:get_if(ifname)
   ifo:stop_query(...)
end

function mdns:insert_if_own_rr(ifname, rr)
   local ifo = self:get_if(ifname)
   ifo:insert_own_rr(rr)
end

function mdns:is_forwardable_rr(rr)
   -- we don't want to publish NSEC entries
   if rr.rtype == dns_const.TYPE_NSEC
   then
      return false
   end

   if rr.rtype == dns_const.TYPE_AAAA
   then
      -- nor do we want to publish linklocal AAAA records
      return not ipv6s.address_is_linklocal(rr.rdata_aaaa)
   end
   return true
end



function mdns:queue_check_propagate_if_rr(ifname, rr)
   local p = self.pending_propagate_check

   -- we don't propagate NSEC records, instead we produce them
   if not self:is_forwardable_rr(rr)
   then
      return
   end

   if not p
   then
      p = dns_db.ns:new{}
      self.pending_propagate_check = p
   end
   local o = p:insert_rr{name=rr.name,
                         rtype=rr.rtype,
                         rclass=dns_const.CLASS_IN,
                         ifname=ifname}
   if o.ifname and o.ifname ~= ifname
   then
      o.ifname = nil
   end
end

function mdns:queue_check_propagate_all()
   -- this is rather brute-force; for EVERY cache interface, check
   -- _everything_. hopefully configuration doesn't change that often..

   -- (we take entries both from cache + own on all interfaces to be
   -- thorough)
   self:iterate_ifs_ns(false, 
                       function (ns, ifo)
                          ns:iterate_rrs(function (rr)
                                            local n = ifo and ifo.ifname
                                            self:queue_check_propagate_if_rr(n, rr)
                                         end)
                       end)
   self:iterate_ifs_ns(true, 
                       function (ns, ifo)
                          ns:iterate_rrs(function (rr)
                                            local n = ifo and ifo.ifname
                                            self:queue_check_propagate_if_rr(n, rr)
                                         end)
                       end)
end

function mdns:run_propagate_check()
   if not self.pending_propagate_check
   then
      return
   end
   local p = self.pending_propagate_check
   self.pending_propagate_check = nil
   p:iterate_rrs(function (rr)
                    self:run_propagate_check_o(rr)
                 end)
end

function mdns:valid_propagate_src_ifo(ifo)
   return true
end

function mdns:valid_propagate_dst_ifo(ifo)
   return true
end

function mdns:run_propagate_check_o(o)
   -- o is rr-ish, but cache_flush, rdata, and so forth are not set
   
   -- first off, detect if there's conflict for this name+rtype
   -- across _all_ caches; if there is, all we need to do is
   -- just remove all related own entries
   local c = 0
   local foundifo
   o.cache_flush = true
   self:iterate_ifs_ns(false, function (ns, ifo)
                          if not self:valid_propagate_src_ifo(ifo)
                          then
                             return
                          end
                          -- see if we can find cache_flush
                          local r = ns:find_rr_list(o)
                          if r
                          then
                             for _, rr in ipairs(r)
                             do
                                if rr.cache_flush
                                then
                                   foundifo = ifo
                                   c = c + 1
                                   return
                                end
                             end
                          end
                          -- similarly, if it has been probed
                          -- for, it is CF name+rtype
                          if ifo and ifo.probe
                          then
                             r = ifo.probe:find_rr_list(o)
                             if r
                             then
                                foundifo = ifo
                                c = c + 1
                             end
                          end
                              end)
   self:d('run_propagate_check_o', o, c, foundifo)
   if c > 1
   then
      -- XXX - we should probably ensure that if the content seen
      -- on both interfaces is same, we can still propagate it;
      -- however, for the time being, we choose not to do that
      self:stop_propagate_unique_o(o)
      return
   end
   
   if c == 1
   then
      self:propagate_unique_ifo_o(foundifo, o)
      return
   end

   -- nothing cache flush found in the whole system; so we can
   -- do the more peaceful 'let all live' kind of propagation occur
   o.cache_flush = false
   self:propagate_shared_o(o)
end

function mdns:stop_propagate_unique_o(o)
   -- go through all interfaces, and propagate empty set for the given o
   self:propagate_o_l_ifo_to_ifs(o)
end

function mdns:propagate_unique_ifo_o(ifo, o)
   -- rather simple - get the set, and propagate that to each
   -- interface
   local r = ifo and ifo.own:find_rr_list(o) 
      or self:find_all_cache_rr_matching_o(o)
   self:propagate_o_l_ifo_to_ifs(o, r, ifo)
end

function mdns:iterate_all_cache_rr_matching_o(o, f)
   self:iterate_ifs_ns(false, function (ns, ifo)
                          ns:iterate_rrs_for_ll(o.name,
                                                function (rr)
                                                   if rr.rtype == o.rtype
                                                   then
                                                      f(rr)
                                                   end
                                               end)
                              end)
end

function mdns:find_all_cache_rr_matching_o(o)
   -- not super lightweight operation, but oh well..
   -- basic idea:

   -- first, gather each entry from caches, taking the one with longest
   -- ttl if same entry encountered multiple times
   local rns = dns_db.ns:new{}

   self:iterate_all_cache_rr_matching_o(o, function (rr)
                                           if rr.rtype ~= o.rtype
                                           then
                                              return
                                           end
                                           local orr = 
                                              rns:insert_rr(rr, true)
                                           if not rr.ttl 
                                              or (orr.ttl 
                                              and orr.ttl < rr.ttl)
                                           then
                                              orr.ttl = rr.ttl
                                           end
                                           end)

   return rns:values()
end

function mdns:propagate_shared_o(o)
   local l = self:find_all_cache_rr_matching_o(o)
   -- then, for each target interface, propagate that set to that interface
   self:propagate_o_l_ifo_to_ifs(o, l)
end

function mdns:propagate_o_l_ifo_to_ifs(o, l, skip_ifo)
   for ifname, ifo in pairs(self.ifname2if)
   do
      if ifo ~= skip_ifo and self:valid_propagate_dst_ifo(ifo)
      then
         -- upsert entries
         ifo:propagate_o_l(o, l)
      else
         -- clear propagation of that stuff on this interface (if any)
         ifo:propagate_o_l(o)
      end
   end
end

-- this implements timeout API, to make sure the MDNS
-- gets all execution time it needs within ssloop 
mdns_runner = mst.create_class{class='mdns_runner', mandatory={'mdns'}}

function mdns_runner:run_timeout()
   -- just call run - timeouts are handled on per-iteration basis
   -- using the get_timeout
   mst.d('calling mdns:run()')
   self.mdns:run()
end

function mdns_runner:get_timeout()
   return self.mdns:next_time()
end

