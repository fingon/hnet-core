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
-- Last modified: Thu Oct 31 08:38:31 2013 mstenber
-- Edit time:     147 min
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

pm_netifd_push = _parent:new_subclass{class='pm_netifd_push',
                                      sources={pm_handler.ni_source,
                                               pm_handler.pa_source,
                                               pm_handler.skv_source,
                                      }}

function pm_netifd_push:init()
   _parent.init(self)

   self.set_netifd_state = {}
   self.device2nh = {}
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
         --ifo.dns_search = self.hp_search
         -- moved to 'data' section

         local p = ipv6s.new_prefix_from_ascii(lap.prefix)
         local is_ipv4 = p:is_ipv4()
         local addrs_name = is_ipv4 and 'ipaddr' or 'ip6addr'
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

         if lap.owner
         then
            local data = _setdefault_named_subentity(ifo, 'data', mst.map)
            if is_ipv4
            then
               data.dhcpv4='server'
            else
               data.dhcpv6='server'
               data.ra='server'
            end
            data.domain=self.hp_search
         end
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

   -- mark external interfaces 'wan'
   local ni = self.ni
   ni:iterate_interfaces(function (ifo)
                            local ifname = ifo.interface
                            local ifo = _setdefault_named_subentity(state, ifname, mst.map)
                            local data = _setdefault_named_subentity(ifo, 'data', mst.map)
                            data.zone = 'wan'
                         end, true, true)

   -- mark internal interfaces 'lan'
   ni:iterate_interfaces(function (ifo)
                            local ifname = ifo.interface
                            local ifo = _setdefault_named_subentity(state, ifname, mst.map)
                            local data = _setdefault_named_subentity(ifo, 'data', mst.map)
                            data.zone = 'lan'
                         end, false, true)
   

   --self:d('produced state', state)
   return state
end

local function convert_to_if_data(now, v)
   if not v
   then
      return nil
   end
   local rest = mst.table_copy(v)
   rest.ipaddr = nil
   rest.ip6addr = nil
   return {now, v.ipaddr, v.ip6addr, rest}
end

-- v1, v2 are _relative_ lifetimes at time t1, t2.
-- what makes them similar? 
function lifetime_similar(t1, v1, t2, v2, ...)
   if not v1 == not not v2
   then
      mst.d('! other has lifetime, other does not')
      return false
   end

   -- no lifetime in either -> win(?)
   if not v1
   then
      return true
   end

   -- special handling for zeros (log won't work here)
   if v1 == 0
   then
      if v2 == 0
      then
         return true
      end
      return false
   end

   -- we're happy if (t1+v2) =~ (t2+v2) given
   -- order of magnitude of v1/v2 >> (a1-a2)
   local a1 = t1 + v1
   local a2 = t2 + v2

   local d = math.abs(a2 - a1)
   if d == 0
   then
      return true
   end
   local magnitude_d = math.log(d)
   local magnitude_v = math.log(mst.min(v1, v2))
   local dm = magnitude_v - magnitude_d
   if dm > 0.3
   then
      return true
   end
   mst.d('! magnitude mismatch', dm, 
         magnitude_d, magnitude_v, t1, v1, t2, v2, ...)
   return false
end

function addr_list_similar(t1, v1, t2, v2, addrtype)
   -- empty lists are similar
   if not v1 and not v2
   then
      return true
   end
   -- one list set, one not, is NOT similar
   if not not v1 == not v2
   then
      mst.d('! one addr list nil')
      return false
   end
   -- if the lists are of different length, they're NOT similar
   if #v1 ~= #v2
   then
      mst.d('! addr lists of different length')
      return false
   end
   for i=1,#v1
   do
      local o1 = mst.table_copy(v1[i])
      local p1 = o1.preferred
      local v1 = o1.valid

      local o2 = mst.table_copy(v2[i])
      local p2 = o2.preferred
      local v2 = o2.valid

      -- initially consider lifetimes

      if not lifetime_similar(t1, p1, t2, p2, 'valid', addrtype)
      then
         return false
      end

      if not lifetime_similar(t1, v1, t2, v2, 'preferred', addrtype)
      then
         return false
      end

      -- then the 'rest' of the content in objects
      o1.preferred = nil
      o1.valid = nil
      o2.preferred = nil
      o2.valid = nil
      if not mst.repr_equal(o1, o2)
      then
         mst.d('! other addr cruft mismatch', o1, o2)
         return false
      end
   end
   return true
end

local function if_data_same(v1, v2)
   -- one of them nil? not same
   if not not v1 == not v2
   then
      mst.d('! one of ifdatas nil')
      return false
   end
   -- both nil? same
   if not v1
   then
      return true
   end
   -- non-addr different?
   if not mst.repr_equal(v1[4], v2[4])
   then
      mst.d('non-addr difference')
      return false
   end
   -- ipv4 addr
   if not addr_list_similar(v1[1], v1[2], v2[1], v2[2], 'ipv4')
   then
      return false
   end
   -- ipv6 addr
   if not addr_list_similar(v1[1], v1[3], v2[1], v2[3], 'ipv6')
   then
      return false
   end
   return true
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
   local now = self:time()
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
                   -- are values same? 
                   function (k, v1, v2)
                      -- we store if_data's in set_netifd_state (v1)
                      return if_data_same(v1, convert_to_if_data(now, v2))
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
   local now = self:time()
   self.set_netifd_state[k] = convert_to_if_data(now, v)
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
