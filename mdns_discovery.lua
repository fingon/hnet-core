#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_discovery.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Mar  5 11:57:53 2013 mstenber
-- Last modified: Mon Nov  4 15:33:18 2013 mstenber
-- Edit time:     30 min
--

-- This is mdns discovery module.

-- What it does, is allows for discovery of the services present on
-- network that haven't been learned of through normal announce
-- process (due to them being up before the mdns.lua is started, or
-- due to network flaps).

-- Basic algorithm:

-- REDUNDANT_FREQUENCY is the time over which we verify that the list
-- of services and the individual service instances are valid

-- We maintain skiplist of what to check, and when, and also dns_db, so
-- that a) lookups are linear time, and so are the to do handling
-- updates etc.

-- This is a stand-alone class mostly for ease of unit testing; in
-- practise, it is closely bound to single mdns_if subclass, as it
-- assumes cache_changed_rr notifications to be propagated here, as
-- well as ability to call the time/query API as needed.

-- Inbound calls:
-- - cache_changed_rr(rr, is_add)
-- - next_time [ to find out when we next want to run ]
-- - run [ to actually run this - i.e. send queries ]

-- Outbound calls:
-- - time (to get current time)
-- - query (to send a query)

require 'mst'
require 'dns_db'

module(..., package.seeall)

-- every minute, even without any indication we should, we _will_ do things
REDUNDANT_FREQUENCY=60
-- (note that this should be ~order of magnitude less than maximum ttl
-- if set (in e.g. hp_core, mdns_core)


SD_ROOT={'_services', '_dns-sd', '_udp', 'local'}

mdns_discovery = mst.create_class{class='mdns_discovery',
                                  mandatory={'query',
                                             'time'},
                                 }

function next_is_less(o1, o2)
   return o1.next < o2.next
end


function mdns_discovery:init()
   self.ns = dns_db.ns:new{}
   self.sl = mst_skiplist.ipi_skiplist:new{lt=next_is_less}
   self:insert_rr{name=SD_ROOT}
end

function mdns_discovery:insert_rr(rr)
   rr.rtype = rr.rtype or dns_const.TYPE_PTR
   rr.rclass = rr.rclass or dns_const.CLASS_IN

   -- if we already have it, do nothing
   local o = self.ns:find_rr(rr)
   if o then return end

   -- we don't have it
   local o = self.ns:insert_rr(rr)

   -- ask for it immediately
   o.next = self.time()

   self.sl:insert(o)
end

function mdns_discovery:remove_rr(rr)
   rr.rtype = rr.rtype or dns_const.TYPE_PTR
   rr.rclass = rr.rclass or dns_const.CLASS_IN

   local o = self.ns:find_rr(rr)
   if not o then return end
   self.sl:remove_if_present(o)
   self.ns:remove_rr(o)
end

function mdns_discovery:cache_changed_rr(rr, add)
   -- ignore non-PTRs
   if rr.rtype ~= dns_const.TYPE_PTR
   then
      return
   end

   -- we _only_ care about direct descendants of SD_ROOT (=services).
   -- the instances are handled within mdns_if, as results of queries
   -- we generate willy nilly here..
   if not dns_db.ll_equal(SD_ROOT, rr.name)
   then
      return
   end

   if not add
   then
      self:remove_rr{name=rr.rdata_ptr}
      return
   end
   self:insert_rr{name=rr.rdata_ptr}
end

function mdns_discovery:next_time()
   local o = self.sl:get_first()
   if o
   then
      return o.next
   end
end

function mdns_discovery:should_run()
   local nt = self:next_time()
   if nt and nt <= self.time()
   then
      return true
   end
end

function mdns_discovery:run()
   local now = self.time()
   local t 

   while true
   do
      local o = self.sl:get_first()
      if not o or o.next > now
      then
         break
      end
      local q = {name=o.name,
                 qclass=o.rclass,
                 qtype=o.rtype,
      }
      self:d('performing discovery query', q)
      -- send query
      self.query(q)

      -- update the next-to-run time
      self.sl:remove(o)
      t = t or {}
      table.insert(t, o)
   end
   if t
   then
      for i, o in ipairs(t)
      do
         o.next = now + REDUNDANT_FREQUENCY
         self.sl:insert(o)
      end
   end
end

