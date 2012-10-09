#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_core.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Oct  4 19:40:42 2012 mstenber
-- Last modified: Tue Oct  9 11:32:13 2012 mstenber
-- Edit time:     75 min
--

-- main class living within PM, with interface to exterior world and
-- to skv

-- (this is testable; pm.lua isn't, as it provides just raw shell
-- access for i/o, and real live skv)

-- obviously, more lowlevel access library (rather than shell) would
-- be an option at some point too; for the time being, just having one
-- command 'run and return results as string' is kind of elegant, and
-- simple. hopefully it won't become bottleneck.

require 'mst'
require 'skv'
require 'elsa_pa'
require 'linux_if'

module(..., package.seeall)

pm = mst.create_class{class='pm', mandatory={'skv', 'shell'}}

function pm:init()
   self.f_lap = function (k, v) self:lap_changed(v) end
   self.f_iflist = function (k, v) self:ifs_changed(v) end
   self.f_usp = function (k, v) self:usp_changed(v) end
   self.skv:add_change_observer(self.f_lap, elsa_pa.OSPF_LAP_KEY)
   self.skv:add_change_observer(self.f_iflist, elsa_pa.OSPF_IFLIST_KEY)
   self.skv:add_change_observer(self.f_usp, elsa_pa.OSPF_USP_KEY)
   self.if_table = linux_if.if_table:new{shell=self.shell} 
end

function pm:uninit()
   self.skv:remove_change_observer(self.f_lap, elsa_pa.OSPF_LAP_KEY)
   self.skv:remove_change_observer(self.f_iflist, elsa_pa.OSPF_IFLIST_KEY)
   self.skv:remove_change_observer(self.f_usp, elsa_pa.OSPF_USP_KEY)
end

function pm:get_real_lap()
   local r = mst.array:new{}

   local m = self.if_table:read_ip_ipv6()

   for _, ifo in ipairs(m:values())
   do
      for _, addr in ipairs(ifo.ipv6 or {})
      do
         local bits = ipv6s.prefix_bits(addr)
         if bits == 64
         then
            -- non-64 bit prefixes can't be eui64 either
            local prefix = ipv6s.eui64_to_prefix(addr)
            mst.a(not r[prefix])
            -- consider if we should even care about this prefix
            local found = nil
            for _, v in ipairs(self.ospf_usp or {})
            do
               self:d('considering', v.prefix, prefix)
               if ipv6s.prefix_contains(v.prefix, prefix)
               then
                  found = v
                  break
               end
            end
            if not found
            then
               self:d('ignoring prefix', prefix)
            else
               local o = {ifname=ifo.name, prefix=prefix, addr=addr}
               self:d('found', o)
               r:insert(o)
            end
         end
      end
   end
   return r
end

function pm:lap_changed(lap)
   self.ospf_lap = lap
   self:check_ospf_vs_real()
end

function pm:usp_changed(usp)
   self.ospf_usp = usp
   self:check_ospf_vs_real()
end

function pm:check_ospf_vs_real()
   if not self.ospf_lap or not self.ospf_usp
   then
      return
   end
   local lap = self.ospf_lap
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
         self:a(not t[v.prefix])
         t[v.prefix] = v
      end
      return t
   end
   local ospf_lap = laplist_to_map(lap)
   local real_lap = laplist_to_map(rlap)
   local ospf_keys = ospf_lap:keys():to_set()
   local real_keys = real_lap:keys():to_set()

   -- 3 cases to consider
   -- only in ospf_lap
   for prefix, _ in pairs(ospf_keys:difference(real_keys))
   do
      self:handle_ospf_prefix(prefix, ospf_lap[prefix])
   end
   
   -- only in real_lap
   for prefix, _ in pairs(real_keys:difference(ospf_keys))
   do
      self:handle_real_prefix(prefix, real_lap[prefix])
   end
   
   -- in both
   for prefix, _ in pairs(real_keys:intersection(ospf_keys))
   do
      self:handle_both_prefix(prefix, ospf_lap[prefix], real_lap[prefix])
   end
end

function pm:handle_ospf_prefix(prefix, po)
   local hwaddr = self.if_table:get_if(po.ifname):get_hwaddr()
   local addr = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
   self:d('handle_ospf_prefix', po)
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr add %s dev %s', addr, po.ifname))
end


function pm:handle_real_prefix(prefix, po)
   -- prefix is only on real interface, but not in OSPF
   -- that means that we want to get rid of it.. let's do so
   self:d('handle_real_prefix', po)
   local addr = po.addr
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr del %s dev %s', addr, ifname))
end

function pm:handle_both_prefix(prefix, po1, po2)
   self:d('handle_both_prefix', po1, po2)
   -- if same prefix is active both in OSPF worldview, and in reality,
   -- we're happy!
   if po1.ifname == po2.ifname
   then
      return
   end
   -- we pretend it's only on real interface (=remove), and then
   -- pretend it's only on OSPF interface (=add)
   self:handle_real_prefix(prefix, po2)
   self:handle_ospf_prefix(prefix, po1)
end

function pm:ifs_changed()
   -- nop?
end
