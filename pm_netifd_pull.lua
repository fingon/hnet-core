#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_pull.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Oct  3 16:48:11 2013 mstenber
-- Last modified: Fri Oct  4 14:28:05 2013 mstenber
-- Edit time:     30 min
--


-- This handler listens to the skv change of
-- 'network-interface-update', and when it detects it, it refreshes
-- the 'network.interface dump' and propagates it to other event
-- handlers.

-- It will also update the pd.* based on the contents of the interface
-- dump.

-- (Note: push is not possible without initial pull, as pull provides
-- the openwrt interface <> real physical device mapping information)

require 'pm_handler'
local json = require "dkjson"

module(..., package.seeall)

NETWORK_INTERFACE_UPDATED_KEY='network-interface-updated'
PROTO_HNET='hnet'

local _parent = pm_handler.pm_handler_with_pa

pm_netifd_pull = _parent:new_subclass{class='pm_netifd_pull'}

function pm_netifd_pull:init()
   _parent.init(self)
   self.set_pd_state = mst.map:new()
   self.last_run = 'xxx' -- force first run, even if just to set this to nil
end

function pm_netifd_pull:get_network_interface_dump()
   local s = self.shell('ubus call network.interface dump')
   return json.decode(s)
end

function pm_netifd_pull:skv_changed(k, v)
   if k == NETWORK_INTERFACE_UPDATED_KEY
   then
      self.updated = v
      self:queue()
   end
end

function pm_netifd_pull:get_pd_state(ni)
   local pd_state = mst.map:new()
   for i, ifo in ipairs(ni.interface)
   do
      for i, p in ipairs(ifo['ipv6-prefix'] or {})
      do
         local device = ifo.l3_device or ifo.device
         local prefix = string.format('%s/%s', p.address, p.mask)
         local now = self:time()
         local o = {[elsa_pa.PREFIX_KEY]=prefix,
                    [elsa_pa.VALID_KEY]=p.valid+now,
                    [elsa_pa.PREFERRED_KEY]=p.preferred+now,
                    -- no prefix class info for now, sigh
                    --[elsa_pa.PREFIX_CLASS_KEY]=pclass,
         }
         local l = pd_state:setdefault_lazy(device, mst.array.new, mst.array)
         l:insert(o)
      end
      for i, d in ipairs(ifo['dns-server'] or {})
      do
         local device = ifo.l3_device or ifo.device
         local l = pd_state:setdefault_lazy(device, mst.array.new, mst.array)

         l:insert{[elsa_pa.DNS_KEY]=d}
      end
      for i, d in ipairs(ifo['dns-search'] or {})
      do
         local device = ifo.l3_device or ifo.device
         local l = pd_state:setdefault_lazy(device, mst.array.new, mst.array)

         l:insert{[elsa_pa.DNS_SEARCH_KEY]=d}
      end
   end
   return pd_state
end

function pm_netifd_pull:run()
   -- don't do anything if there does not seem to be a need
   if self.last_run == self.updated
   then
      return
   end
   self.last_run = self.updated

   -- there isn't any useful way how we can verify it isn't same ->
   -- just forward it as-is
   local ni = self:get_network_interface_dump()
   function ni:device2interface(d, filter)
      -- 'ifname' we get from skv (and therefore OSPF) is actually real
      -- Linux device name. netifd deals with 'interface's => we have to adapt
      local interface_list = self.interface
      mst.a(interface_list, 'no interface list?!?')
      for i, v in ipairs(interface_list)
      do
         if v.l3_device == d and (not filter or filter(v, d))
         then
            return v.interface
         end
      end
      -- fallback - accept non-l3_devices too
      for i, v in ipairs(interface_list)
      do
         if v.device == d and (not filter or filter(v, d))
         then
            return v.interface
         end
      end
   end

   function ni:device2hnet_interface(d)
      return self:device2interface(d, function (v)
                                      return v.proto == PROTO_HNET
                                      end)
   end

   function ni:interface2device(i)
      local interface_list = self.interface
      mst.a(interface_list, 'no interface list?!?')
      for i, v in ipairs(interface_list)
      do
         if v.interface == i
         then
            return v.l3_device or v.device
         end
      end
   end

   self._pm.network_interface_changed(ni)

   -- second thing we do is update pd.* in skv; we're responsible for
   -- keeping that in sync with whatever is in netifd 
   local pd_state = self:get_pd_state(ni)

   -- synchronize them with 'known state'
   mst.sync_tables(self.set_pd_state, pd_state, 
                   -- remove
                   function (k)
                      self._pm.skv:set('pd.' .. k, {})
                      self.set_pd_state[k] = nil
                   end,
                   -- add
                   function (k, v)
                      self._pm.skv:set('pd.' .. k, v)
                      self.set_pd_state[k] = v
                   end,
                   -- are values same? use repr
                   function (k, v1, v2)
                      return mst.repr(v2) == mst.repr(v1)
                   end)

end
