#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_firewall.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Oct  7 12:12:07 2013 mstenber
-- Last modified: Mon Oct  7 14:50:25 2013 mstenber
-- Edit time:     44 min
--

-- This code is responsible for adapting the firewall status of the
-- system to that what we consider currently valid.

-- We _only_ handle 'hnet' proto interfaces.

-- 'Algorithm'

-- - initally set all interfaces to lan

-- - listen to network interface dump changes

-- - for everything with ipv6-prefix, set associated hnet interface to wan

-- - commit changes to uci if any detected

require 'pm_handler'

module(..., package.seeall)

local _parent = pm_handler.pm_handler

pm_netifd_firewall = _parent:new_subclass{class='pm_netifd_firewall'}

function pm_netifd_firewall:init()
   _parent.init(self)

   -- we keep two lists in sync with the system: all _our_ interfaces
   -- in lan and wan state (and additionally, we get system's current
   -- ones when doing changes so that we don't remove anything that
   -- has been set there by non-hnet case)
   self.set_lan_state = {}
   self.set_wan_state = {}

   self:connect_method(self._pm.network_interface_changed, self.ni_changed)
end

function pm_netifd_firewall:ni_changed(ni)
   self:d('ni_changed')
   self.ni = ni
   self:queue()
end

function pm_netifd_firewall:ready()
   self:d('ready?', self.ni ~= nil)
   return self.ni
end

function pm_netifd_firewall:get_state()
   local wan_state = mst.set:new()

   local ni = self.ni

   for i, ifo in ipairs(ni.interface)
   do
      local prefixes = ifo['ipv6-prefix'] or {}
      if #prefixes > 0
      then
         local device = ifo.l3_device or ifo.device
         local hnet_ifname = ni:device2hnet_interface(device)
         if hnet_ifname
         then
            wan_state:insert(hnet_ifname)
         end
      end
   end  

   local lan_state = mst.set:new()
   for i, ifo in ipairs(ni.interface)
   do
      local ifname = ifo.interface
      if ifo.proto == pm_netifd_pull.PROTO_HNET and not wan_state[ifname]
      then
         self:a(ifname, 'no ifname?!?', ifo)
         lan_state:insert(ifname)
      end
   end
   local lan_list = lan_state:keys()
   table.sort(lan_list)

   local wan_list = wan_state:keys()
   table.sort(wan_list)

   return lan_list, wan_list
end

function pm_netifd_firewall:get_uci_cursor()
   require 'uci'
   return uci.cursor()
end

function pm_netifd_firewall:set_uci_firewall(c, zonename, include, exclude)
   local found
   self:d('set_uci_firewall', zonename, include, exclude)
   c:foreach('firewall', 'zone', function (s)
                self:d(' considering', s)
                if s.name == zonename
                then
                   local nw = s.network or {}
                   -- seems like owrt provides these lists as strings..
                   if type(nw) == 'string'
                   then
                      nw = mst.string_split(nw, ' ')
                   end
                   local ns = mst.array_to_set(nw)
                   local is = mst.array_to_set(include)
                   local es = mst.array_to_set(exclude)
                   self:d(' doing set up', ns, is, es)
                   ns = ns:union(is):difference(es)
                   found = true
                   local nl = ns:keys()
                   table.sort(nl)
                   self:d(' got', nl)
                   c:set('network', s['.name'], 'network', nl)
                   return false
                end
                                 end)
   return found
end

function pm_netifd_firewall:run()
   local ls, ws = self:get_state()
   -- nop if we already have what we wanted
   if mst.repr_equal(ls, self.set_lan_state) and mst.repr_equal(ws, self.set_wan_state)
   then
      return
   end
   self.set_lan_state = ls
   self.set_wan_state = ws
   local c = self:get_uci_cursor()
   if not c
   then
      return
   end
   local c1 = self:set_uci_firewall(c, 'lan', ls, ws)
   local c2 = self:set_uci_firewall(c, 'wan', ws, ls)
   if c1 or c2
   then
      self:d('committing changes')

      c:commit()
   end
end
