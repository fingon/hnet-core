#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v4_addr.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 07:14:12 2012 mstenber
-- Last modified: Mon Sep 30 17:16:55 2013 mstenber
-- Edit time:     7 min
--

require 'pm_handler'

module(..., package.seeall)

pm_v4_addr = pm_handler.pm_handler_with_pa:new_subclass{class='pm_v4_addr'}

function pm_v4_addr:run()
   local m = self:get_if_table():read_ip_ipv4()
   local if2a = {}

   -- this is what we _want_ (OSPF-based)
   for i, lap in ipairs(self.lap)
   do
      if lap.address
      then
         if ipv6s.address_is_ipv4(lap.address)
         then
            if2a[lap.ifname] = lap.address
         end
      end
   end

   -- this is what we have
   local hif2a = {}
   for ifname, ifo in pairs(m)
   do
      if ifo.ipv4
      then
         -- just store address, no mask; but if mask isn't 24, we just
         -- ignore whole address
         local l = mst.string_split(ifo.ipv4, '/')
         if l[2] == '24'
         then
            local s = l[1]
            hif2a[ifname] = s
         end
      end
   end

   self:d('got', hif2a)
   self:d('want', if2a)


   -- then fire up the sync algorithm
   local c = mst.sync_tables(hif2a, if2a,
                             -- remove
                             function (ifname, v)
                                -- nop
                                -- we don't remove addresses, as that could be
                                -- counterproductive in so many ways;
                                -- we are not the sole source of addresses
                             end,
                             -- add
                             function (ifname, v)
                                local ifo = self:get_if_table():get_if(ifname)
                                ifo:set_ipv4(v, '255.255.255.0')
                             end,
                             -- equal
                             function (k, v1, v2)
                                return v1 == v2
                             end)
   return c
end

