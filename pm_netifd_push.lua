#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_push.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Oct  2 12:54:49 2013 mstenber
-- Last modified: Wed Oct  9 14:18:55 2013 mstenber
-- Edit time:     86 min
--

-- This is unidirectional channel which pushes the 'known state' of
-- skv towards netifd.

-- Basic idea: No change -> nothing occurs.

-- The code generates per-interface blobs for every interface ever
-- seen, but if there's no change, no push towards netifd is done.

-- Pushing itself is done using ubus command line tool, to make this
-- easy to unit test; it could be equally well done with ubus Lua
-- module

require 'pm_handler'
require 'pm_radvd'

module(..., package.seeall)

DEFAULT_METRIC=1024

local _parent = pm_handler.pm_handler_with_pa_dns

pm_netifd_push = _parent:new_subclass{class='pm_netifd_push'}

function pm_netifd_push:init()
   _parent.init(self)
   self.set_netifd_state = {}
   self.device2nh = {}
   self:connect_method(self._pm.network_interface_changed, self.ni_changed)
end

function pm_netifd_push:ni_changed(ni)
   self.ni = ni
   self:queue()
end

function pm_netifd_push:ready()
   -- we can't do anything useful until we have network interface dump available
   -- (from pm_netifd_pull)
   return _parent.ready(self) and self.ni
end

function pm_netifd_push:get_skv_to_netifd_state()
   local state = mst.map:new()
   -- use usp + lap to produce per-interface info blobs we feed to netifd
   local function _setdefault_named_subentity(o, n, class_object)
      return o:setdefault_lazy(n, class_object.new, class_object)
   end
   -- dig out addresses from lap
   for i, lap in ipairs(self.lap)
   do
      local ifname = self.ni:device2hnet_interface(lap.ifname)
      if ifname and lap.address
      then
         local ifo = _setdefault_named_subentity(state, ifname, mst.map)

         -- make sure we announce hp search on this
         ifo.dns_search = self.hp_search

         local p = ipv6s.new_prefix_from_ascii(lap.prefix)
         local addrs_name = p:is_ipv4() and 'ipaddr' or 'ip6addr'
         local addrs = _setdefault_named_subentity(ifo, addrs_name, mst.array)
         local _, mask = unpack(mst.string_split(lap.prefix, '/'))
         local now = self:time()
         local pref = pm_radvd.abs_to_delta(now, lap[elsa_pa.PREFERRED_KEY])
         local valid = pm_radvd.abs_to_delta(now, lap[elsa_pa.VALID_KEY])
         local o = {
            ipaddr=lap.address,
            mask=mask,
            preferred=pref,
            valid=valid,
         }
         addrs:insert(o)
         self:d('added address', addrs_name, o)

      end
   end

   -- dig out routes from usp
   for i, usp in ipairs(self.usp)
   do
      -- ifname + nh == source route we care about (we're internal
      -- node, and it needs to point somewhere external)
      local devname = usp.ifname
      local ifname = self.ni:device2hnet_interface(devname)
      if ifname 
      then

         local nh = usp.nh or self.device2nh[devname]
         if nh
         then
            local ifo = _setdefault_named_subentity(state, ifname, mst.map)
            local p = ipv6s.new_prefix_from_ascii(usp.prefix)
            local routes_name = p:is_ipv4() and 'routes' or 'routes6'
            local routes = _setdefault_named_subentity(ifo, routes_name, mst.array)
            local o = {
               source=usp.prefix,
               target=p:is_ipv4() and '0.0.0.0/0' or '::/0',
               gateway=nh,
               metric=DEFAULT_METRIC,
               -- metric/valid?
            }
            routes:insert(o)
            self:d('added route', routes_name, o)
         else
            self:d('no nh found for usp', usp, ifname, devname)
         end
      end
   end
   --self:d('produced state', state)
   return state
end

function pm_netifd_push:run()
   -- determine the local next hops on interfaces
   -- (e.g. have 'route', with target '::' and nexthop)
   self.device2nh = {}
   local function _iterate_ext_route(ifo)
      for i, r in ipairs(ifo['route'] or {})
      do
         if r.target == '::' and r.nexthop
         then
            self.device2nh[ifo.l3_device or ifo.device] = r.nexthop
         end
      end
   end
   self.ni:iterate_interfaces(_iterate_ext_route, true)

   -- generate per-interface blobs
   local state = self:get_skv_to_netifd_state()

   local zapping = {}
   
   -- synchronize them with 'known state'
   mst.sync_tables(self.set_netifd_state, state, 
                   -- remove
                   function (k)
                      zapping[k] = true
                   end,
                   -- add
                   function (k, v)
                      zapping[k] = nil
                      self:push_state(k, v)
                   end,
                   -- are values same? use repr
                   function (k, v1, v2)
                      -- we store repr's in set_netifd_state
                      return mst.repr(v2) == v1
                   end)

   -- for those interfaces that we do not have fresh state for, send
   -- empty state update
   for k, v in pairs(zapping)
   do
      self:push_state(k, {})
   end
end

function pm_netifd_push:push_state(k, v)
   self:d('push_state', k)
   self.set_netifd_state[k] = mst.repr(v)
   v.interface = k
   v['link-up'] = true
   v.action = 0
   -- xxx - better escaping some day..
   local conn = self:get_ubus_connection()
   self:a(conn, 'unable to connect ubus')
   local r = conn:call('network.interface', 'notify_proto', v)
   conn:close()
   return r
end
