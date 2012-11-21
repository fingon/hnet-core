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
-- Last modified: Wed Nov 21 18:37:53 2012 mstenber
-- Edit time:     3 min
--

require 'pm_handler'

module(..., package.seeall)

pm_v4_addr = pm_handler.pm_handler:new_subclass{class='pm_v4_addr'}

function pm_v4_addr:ready()
   return self.pm.ospf_lap
end

function pm_v4_addr:run()
   local m = self.pm.if_table:read_ip_ipv4()
   local if2a = {}

   -- this is what we _want_ (OSPF-based)
   for i, lap in ipairs(self.pm.ospf_lap)
   do
      if lap.address
      then
         -- just store address, no mask (we assume it's sane)
         if2a[lap.ifname] = mst.string_split(lap.address, '/')[1]
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
                                -- don't hinder the -4 dhclient by changing address under it
                                if self.pm.dhclient_ifnames[ifname]
                                then
                                   self:d(' ignoring dhclient interface', ifname)

                                   return
                                end

                                local ifo = self.pm.if_table:get_if(ifname)
                                ifo:set_ipv4(v, '255.255.255.0')
                             end,
                             -- equal
                             function (k, v1, v2)
                                return v1 == v2
                             end)
   return c
end

