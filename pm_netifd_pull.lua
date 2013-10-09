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
-- Last modified: Wed Oct  9 17:03:11 2013 mstenber
-- Edit time:     72 min
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

module(..., package.seeall)

NETWORK_INTERFACE_UPDATED_KEY='network-interface-updated'
PROTO_HNET='hnet'

local _parent = pm_handler.pm_handler_with_pa

-- abstraction class around the structure we get from ubus that
-- represents the current network state

network_interface_dump = mst.create_class{class='network_interface_dump'}

function network_interface_dump:repr_data()
   return '?'
end

function network_interface_dump:get_device2interface_multimap()
   if not self.device2ifo
   then
      local mm = mst.multimap:new{}
      for i, ifo in ipairs(self.interface)
      do
         local dev = ifo.l3_device or ifo.device
         if dev
         then
            mm:insert(dev, ifo)
         end
      end
      self.device2ifo = mm
   end
   return self.device2ifo
end

function network_interface_dump:device2interface(d, filter)
   local d2i = self:get_device2interface_multimap()
   for i, v in ipairs(d2i[d] or {})
   do
      if (not filter or filter(v, d))
      then
         return v.interface
      end
   end
end

function network_interface_dump:ifo_is_itself_external(ifo)
   local pl = ifo['ipv6-prefix']
   local is_ext = pl and #pl > 0
   return is_ext
end

function network_interface_dump:device2hnet_interface(d)
   return self:device2interface(d, function (v)
                                   return v.proto == PROTO_HNET
                                   end)
end

function network_interface_dump:device_is_external(d)
   return self:device2interface(d, function (ifo)
                                   return self:ifo_is_itself_external(ifo)
                                   end)
end

function network_interface_dump:ifo_is_external(ifo)
   -- this is nontrivial to determine; what we have to do is to make
   -- sure that the underlying _device_ is external.. and that depends
   -- on every interface object attached to that device.
   local dev = ifo.l3_device or ifo.device
   return self:device_is_external(dev)
end

function network_interface_dump:interface2device(i)
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

function network_interface_dump:iterate_interfaces(f, want_ext, want_hnet)
   self:d('starting iteration', not not want_ext, not not want_hnet)

   for i, ifo in ipairs(self.interface)
   do
      local is_hnet = ifo.proto == PROTO_HNET 
      local is_ext = self:ifo_is_external(ifo)
      local match = (want_ext == nil or (not want_ext == not is_ext)) and
         (want_hnet == nil or (not want_hnet == not is_hnet))
      self:d('iteratating', ifo.interface, is_ext, is_hnet, match)
      if match
      then
         f(ifo)
      end
   end
end

pm_netifd_pull = _parent:new_subclass{class='pm_netifd_pull'}

function pm_netifd_pull:init()
   _parent.init(self)
   self.set_pd_state = mst.map:new()
   self.set_dhcp_state = mst.map:new()
   self.last_run = 'xxx' -- force first run, even if just to set this to nil
end

function pm_netifd_pull:get_network_interface_dump()
   local conn = self:get_ubus_connection()
   self:a(conn, 'unable to connect ubus')
   local r = conn:call('network.interface', 'dump', {})
   setmetatable(r, network_interface_dump)
   conn:close()
   return r
end

function pm_netifd_pull:skv_changed(k, v)
   if k == NETWORK_INTERFACE_UPDATED_KEY
   then
      self.updated = v
      self:queue()
   end
end

function pm_netifd_pull:get_state(ni)
   local pd_state = mst.map:new()
   local dhcp_state = mst.map:new()
   local function _ext_if_iterator(ifo)
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
         local state = ipv6s.address_is_ipv4(d) and dhcp_state or pd_state
         local l = state:setdefault_lazy(device, mst.array.new, mst.array)
         l:insert{[elsa_pa.DNS_KEY]=d}
      end
      for i, d in ipairs(ifo['dns-search'] or {})
      do
         local device = ifo.l3_device or ifo.device
         local l = pd_state:setdefault_lazy(device, mst.array.new, mst.array)

         l:insert{[elsa_pa.DNS_SEARCH_KEY]=d}
      end

   end
   ni:iterate_interfaces(_ext_if_iterator, true)
   return pd_state, dhcp_state
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

   self._pm.network_interface_changed(ni)

   -- second thing we do is update pd.* in skv; we're responsible for
   -- keeping that in sync with whatever is in netifd 
   local pd_state, dhcp_state = self:get_state(ni)

   -- synchronize them with 'known state'
   mst.sync_tables(self.set_pd_state, pd_state, 
                   -- remove
                   function (k)
                      self._pm.skv:set(elsa_pa.PD_SKVPREFIX .. k, {})
                      self.set_pd_state[k] = nil
                   end,
                   -- add
                   function (k, v)
                      self._pm.skv:set(elsa_pa.PD_SKVPREFIX .. k, v)
                      self.set_pd_state[k] = v
                   end,
                   -- are values same? use repr
                   function (k, v1, v2)
                      return mst.repr(v2) == mst.repr(v1)
                   end)

   -- synchronize them with 'known state'
   mst.sync_tables(self.set_dhcp_state, dhcp_state, 
                   -- remove
                   function (k)
                      self._pm.skv:set(elsa_pa.DHCPV4_SKVPREFIX .. k, {})
                      self.set_dhcp_state[k] = nil
                   end,
                   -- add
                   function (k, v)
                      self._pm.skv:set(elsa_pa.DHCPV4_SKVPREFIX .. k, v)
                      self.set_dhcp_state[k] = v
                   end,
                   -- are values same? use repr
                   function (k, v1, v2)
                      return mst.repr(v2) == mst.repr(v1)
                   end)

end
