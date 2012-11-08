#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_route.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 06:48:34 2012 mstenber
-- Last modified: Thu Nov  8 07:35:32 2012 mstenber
-- Edit time:     5 min
--

-- pm_v6_route is responsible for syncing the real state to ospf_lap/usp 
-- by manipulating the routes

require 'pm_handler'

module(..., package.seeall)

local ipv4_end='/24' -- as it's really v4 looking string

pm_v6_route = pm_handler.pm_handler:new_subclass()

function pm_v6_route:ready()
   return self.pm.ospf_lap and self.pm.ospf_usp
end


function pm_v6_route:run()
   local valid_end='::/64'
   local lap = self.pm.ospf_lap
   local rlap = self:get_real_lap()
   self:d('lap_changed - rlap/lap', #rlap, #lap)
   -- both are lists of map's, with prefix+ifname keys
   --
   -- convert them to single table
   -- (prefixes should be unique, interfaces not necessarily)
   function laplist_to_map(l)
      local t = mst.map:new{}
      for i, v in ipairs(l)
      do
         local ov = t[v.prefix]

         if not mst.string_endswith(v.prefix, ipv4_end)
         then
            -- if we don't have old value, or old one is 
            -- depracated, we clearly prefer the new one

            -- XXX - add test cases for this
            if not ov or ov.depracate
            then
               t[v.prefix] = v
            end
         end
      end
      return t
   end
   local ospf_lap = laplist_to_map(lap)
   local real_lap = laplist_to_map(rlap)
   local ospf_keys = ospf_lap:keys():to_set()
   local real_keys = real_lap:keys():to_set()

   local c
   c = mst.sync_tables(real_keys, ospf_keys, 
                       -- remove (only in real)
                       function (prefix)
                          mst.a(mst.string_endswith(prefix, valid_end),
                                'invalid prefix', prefix)
                          self:handle_real_prefix(prefix, real_lap[prefix])
                       end,
                       -- add (only in ospf)
                       function (prefix)
                          mst.a(mst.string_endswith(prefix, valid_end),
                                'invalid prefix', prefix)
                          self:handle_ospf_prefix(prefix, ospf_lap[prefix])
                       end,
                       -- are values same?
                       function (prefix)
                          mst.a(mst.string_endswith(prefix, valid_end),
                                'invalid prefix', prefix)
                          local v1 = ospf_lap[prefix]
                          local v2 = real_lap[prefix]
                          return v1.ifname == v2.ifname
                       end)

   -- rewrite the radvd configuration
   if c > 0
   then
      self:changed()
   end
   return 1
end

function pm_v6_route:get_real_lap()
   local r = mst.array:new{}

   local m = self.pm.if_table:read_ip_ipv6()

   for _, ifo in ipairs(m:values())
   do
      for _, addr in ipairs(ifo.ipv6 or {})
      do
         local prefix = ipv6s.new_prefix_from_ascii(addr)
         local bits = prefix:get_binary_bits()
         if bits == 64
         then
            -- non-64 bit prefixes can't be eui64 either
            -- consider if we should even care about this prefix
            local found = nil
            prefix:clear_tailing_bits()
            for _, p2 in pairs(self.pm.all_ipv6_binary_prefixes)
            do
               --self:d('considering', v.prefix, prefix)
               if p2:contains(prefix)
               then
                  found = true
                  break
               end
            end
            if not found
            then
               self:d('ignoring prefix', prefix)
            else
               local o = {ifname=ifo.name, 
                          prefix=prefix:get_ascii(), 
                          addr=addr}
               self:d('found', o)
               r:insert(o)
            end
         end
      end
   end
   return r
end


function pm_v6_route:handle_ospf_prefix(prefix, po)
   local hwaddr = self.pm.if_table:get_if(po.ifname):get_hwaddr()
   local addr = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
   self:d('handle_ospf_prefix', po)
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr add %s dev %s', addr, po.ifname))
end


function pm_v6_route:handle_real_prefix(prefix, po)
   -- prefix is only on real interface, but not in OSPF
   -- that means that we want to get rid of it.. let's do so
   self:d('handle_real_prefix', po)
   local addr = po.addr
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr del %s dev %s', addr, ifname))
end

