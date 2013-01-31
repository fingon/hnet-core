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
-- Last modified: Thu Jan 31 11:18:01 2013 mstenber
-- Edit time:     877 min
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
require 'dnscodec'
require 'dnsdb'
require 'mdns_if'
require 'mdns_const'
require 'linux_if'

IF_INFO_VALIDITY_PERIOD=60

module(..., package.seeall)

-- global mdns structure, which mostly just deals with different
-- mdns_if instances
mdns = mst.create_class{class='mdns', 
                        ifclass=mdns_if.mdns_if,
                        time=os.time,
                        mandatory={'sendto', 'shell'}}

function mdns:init()
   self.ifname2if = {}
end

function mdns:get_local_binary_prefix_set()
   local now = self.time()
   local was = self.local_binary2ifname_refresh
   if not was or (was + IF_INFO_VALIDITY_PERIOD) < now
   then
      -- TODO - consider if it is worth storing this if_table;
      -- for the time being, we save memory by not keeping it around..
      local if_table = linux_if.if_table:new{shell=self.shell} 

      if_table:read_ip_ipv6()
      local m = {}
      for ifname, ifo in pairs(if_table.map)
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
      self.local_binary2ifname_refresh = now
      self.local_binary2ifname = m
   end
   return self.local_binary2ifname
end

function mdns:is_local_binary_prefix(b)
   -- shortcut - if it was on last refresh, we don't really
   -- care now (assume the host doesn't move that much)
   local v = self.local_binary2ifname and self.local_binary2ifname[b]
   if v
   then
      return v
   end
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
   end
   return o
end

function mdns:iterate_ifs_ns(key, f)
   self:a(f, 'nil function')
   for ifname, o in pairs(self.ifname2if)
   do
      local ns = o[key]
      ns:iterate_rrs(f)
   end
end

function mdns:iterate_ifs_ns_matching_q(key, q, f)
   for ifname, o in pairs(self.ifname2if)
   do
      -- nil = no kas
      mdns_if.iterate_ns_matching_query(o[key], q, nil, f)
   end
end

function mdns:repr_data()
   return '?'
end

function mdns:run()
   self.now = self.time()
   -- expire items
   for ifname, o in pairs(self.ifname2if)
   do
      o:run()
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
   for ifname, ifo in pairs(self.ifname2if)
   do
      local b = ifo:next_time()
      if not best or (b and b < best)
      then
         best = b
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
   self:iterate_ifs_ns('own', 
                       function ()
                          c = c + 1
                       end)
   return c
end

function mdns:cache_count()
   local c = 0
   self:iterate_caches(function (ns)
                          ns:iterate_rrs(function (rr)
                                            c = c + 1
                                         end)
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

function mdns:iterate_caches(f)
   for toif, ifo in pairs(self.ifname2if)
   do
      f(ifo.cache, ifo)
   end
end

function mdns:if_rr_has_cache_conflicts(ifname, rr)
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
   self:iterate_caches(function (ns, ifo)
                          if ifo.ifname ~=  ifname
                          then
                             -- unfortunately, we have to consider
                             -- _all_ records that match the name =>
                             -- not insanely efficient.. but oh
                             -- well. we know specifically what we're
                             -- looking for, after all.
                             local conflict
                             ns:iterate_rrs_for_ll(rr.name, 
                                                   function (o)
                                                      if o.cache_flush
                                                      then
                                                         self:d('found conflict for ', rr, o)
                                                         conflict = true
                                                      end
                                                   end)
                             if conflict then return true end
                          end

                       end)
end

-- These four are 'overridable' functionality for the
-- subclasses; basically, how the different cases of propagating
-- cache rr's state onward are handled
-- (.. or if they are!)
function mdns:propagate_if_rr(ifname, rr)
end

function mdns:stop_propagate_conflicting_if_rr(ifname, rr, clear_rrset)
   -- same we can keep
   for ifname, ifo in pairs(self.ifname2if)
   do
      ifo:stop_propagate_conflicting_rr_sub(rr, clear_rrset)
   end
end

function mdns:expire_if_cache_rr(ifname, rr)
   --this should happen on it's own as the own entries also have
   --(by default) assumedly ttl's

   --self:stop_propagate_rr_sub(rr, ifname, false, true)
end
