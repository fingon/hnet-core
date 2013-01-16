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
-- Last modified: Wed Jan 16 19:56:34 2013 mstenber
-- Edit time:     836 min
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

module(..., package.seeall)

-- global mdns structure, which mostly just deals with different
-- mdns_if instances
mdns = mst.create_class{class='mdns', 
                        subclass=mdns_if.mdns_if,
                        time=os.time,
                        mandatory={'sendto'}}

function mdns:init()
   self.ifname2if = {}
end

function mdns:get_if(ifname)
   mst.a(type(ifname) == 'string', 'non-string ifname', ifname)
   local o = self.ifname2if[ifname]
   if not o
   then
      o = self.subclass:new{ifname=ifname, parent=self}
      self.ifname2if[ifname] = o
   end
   return o
end

function mdns:iterate_ifs_rr(key, rr, f, similar, equal)
   for ifname, o in pairs(self.ifname2if)
   do
      if rr
      then
         -- no kas
         mdns_if.iterate_ns_matching_query(o[key], rr, nil, f, similar, equal)
      else
         for i, rr in ipairs(o[key]:values())
         do
            f(rr)
         end
      end
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
   self:a(srcport, 'srcport not set')
   self:a(src, 'src not set')
   self:a(data, 'data not set')

   local l = mst.string_split(src, '%')
   mst.a(#l == 2, 'invalid src', src)
   local addr, ifname = unpack(l)
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
   self:iterate_ifs_rr('own', nil, 
                       function ()
                          c = c + 1
                       end)
   return c
end

function mdns:cache_count()
   local c = 0
   self:iterate_ifs_rr('cache', nil, 
                       function ()
                          c = c + 1
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
   for toif, ifo in pairs(self.ifname2if)
   do
      local ns = ifo.cache
      -- XXX - should we care if if is master or not?
      -- probably not

      -- unfortunately, we have to consider _all_ records that match
      -- the name => not insanely efficient.. but oh well. we know
      -- specifically what we're looking for, after all.
      local conflict
      mdns_if.iterate_ns_rr(ns, rr, function (o)
                               self:d('found conflict for ', rr, o)
                               conflict = true
                                    end, true, false)
      if conflict then return true end
   end
end

-- These four are 'overridable' functionality for the
-- subclasses; basically, how the different cases of propagating
-- cache rr's state onward are handled
-- (.. or if they are!)
function mdns:propagate_rr(rr, ifname)
end

function mdns:stop_propagate_conflicting_rr(rr, ifname)
   -- same we can keep
   for ifname, ifo in ipairs(self.ifname2if)
   do
      ifo:stop_propagate_rr_sub(rr, true, false)
   end
end

function mdns:expire_rr(rr, ifname)
   --this should happen on it's own as the own entries also have
   --(by default) assumedly ttl's

   --self:stop_propagate_rr_sub(rr, ifname, false, true)
end
