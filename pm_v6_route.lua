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
-- Last modified: Thu Jun 27 11:02:41 2013 mstenber
-- Edit time:     20 min
--

-- pm_v6_route is responsible for syncing the real state to
-- ospf_lap/usp by manipulating the configured interfaces' addresses
-- (and implicitly, routes). we could also directly interact with the
-- RIB if we chose to.

require 'pm_handler'
require 'ipv6s'

module(..., package.seeall)

local ipv4_end='/24' -- as it's really v4 looking string

pm_v6_route = pm_handler.pm_handler:new_subclass{class='pm_v6_route'}

function pm_v6_route:ready()
   return self.pm.ospf_lap and self.pm.ospf_usp
end

local function laplist_to_map(l)
   local t = mst.map:new{}
   for i, v in ipairs(l)
   do
      local ov = t[v.prefix]

      -- if we don't have old value, or old one is 
      -- depracated, we clearly prefer the new one
      if not ov or ov.depracate
      then
         t[v.prefix] = v
      end
   end
   return t
end

function pm_v6_route:run()
   local valid_end='::/64'
   local lap = self.pm:get_ipv6_lap()
   local rlap = self:get_real_lap()
   self:d('lap_changed - rlap/lap', #rlap, #lap)
   -- both are lists of map's, with prefix+ifname keys
   --
   -- convert them to single table
   -- (prefixes should be unique, interfaces not necessarily)
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
   return c
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
   self:a(po.ifname, 'no ifname in lap', po)
   local hwaddr = self.pm.if_table:get_if(po.ifname):get_hwaddr()
   local addr = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
   self:d('handle_ospf_prefix', po)
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   local ifo = self.pm.if_table:get_if(ifname)
   return ifo:add_ipv6(addr)
end


function pm_v6_route:handle_real_prefix(prefix, po)
   -- prefix is only on real interface, but not in OSPF
   -- that means that we want to get rid of it.. let's do so
   self:d('handle_real_prefix', po)
   local addr = po.addr
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   local ifo = self.pm.if_table:get_if(ifname)
   return ifo:del_ipv6(addr)
end

