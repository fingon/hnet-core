#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_core.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Oct  4 19:40:42 2012 mstenber
-- Last modified: Wed Feb 27 12:45:29 2013 mstenber
-- Edit time:     558 min
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
require 'os'
require 'pa'


module(..., package.seeall)

PID_DIR='/var/run'
CONF_PREFIX='/tmp/pm-'

-- if not provided to the pm class, these are used
DEFAULT_FILENAMES={radvd_conf_filename='radvd.conf',
                   dhcpd_conf_filename='dhcpd.conf',
                   dhcpd6_conf_filename='dhcpd6.conf',
                   dnsmasq_conf_filename='dnsmasq.conf',
}

pm = mst.create_class{class='pm', mandatory={'skv', 'shell'}}

function pm:service_name_to_service(name)
   name = self.rewrite_service[name] or name
   return self.h[name]
end

function pm:connect_changed(srcname, dstname)
   local o = self:service_name_to_service(srcname)
   local o2 = self:service_name_to_service(dstname)
   self:a(o, 'missing service (src)', srcname)
   self:a(o2, 'missing service (dst)', dstname)
   o:connect_method(o.changed, o2, o2.queue)
end

function pm:queue(name)
   local o = self:service_name_to_service(name)
   self:a(o, 'missing service', name)
   if o:queue()
   then
      self:d('queued', o)
   end
end

function pm:replace_handlers(d)
   -- first off, create new list of handlers _without_ any in the d src
   self.handlers = self.handlers:filter(function (x)
                                           return not d[x]
                                        end)
   for k, v in pairs(d)
   do
      self.rewrite_service[k] = v
      if not self.handlers:find(v)
      then
         self.handlers:insert(v)
      end
   end
end


function pm:init()
   self.changes = 0
   self.f = function (k, v) self:kv_changed(k, v) end
   self.h = {}
   self.rewrite_service = {}

   for k, v in pairs(DEFAULT_FILENAMES)
   do
      self[k] = self[k] or CONF_PREFIX .. v
   end
   -- !!! These are in MOSTLY alphabetical order for the time being.
   -- DO NOT CHANGE THE ORDER (at least without fixing the pm_core_spec as well)
   self.handlers = mst.array:new{
      'bird4',
      'dhcpd',
      'v4_addr',
      'v4_dhclient',
      'v6_dhclient',
      'v6_listen_ra',
      'v6_nh',
      'v6_route',
      'v6_rule',
      -- radvd depends on v6_route => it is last
      'radvd',
      -- this doesn't matter, it just has tick
      'memory',
      
   }
   if self.use_dnsmasq
   then
      self:replace_handlers{radvd='dnsmasq',
                            dhcpd='dnsmasq'}
   end

   if self.use_fakedhcpv6d
   then
      -- dhcpd will take care of v4 only, and v6 IA_NA replies will be
      -- provided by fakedhcpv6d
      self.handlers:insert('fakedhcpv6d')
   end


   -- shared datastructures
   self.if_table = linux_if.if_table:new{shell=self.shell} 
   -- IPv6 next hops - ifname => nh-list
   self.nh = mst.multimap:new{}

   for i, v in ipairs(self.handlers)
   do
      local v2 = 'pm_' .. v
      local m = require(v2)
      local o = m[v2]:new{pm=self}
      self.h[v] = o
      -- make sure it updates self.changes if it changes
      o:connect(o.changed, function ()
                   self.changes = self.changes + 1
                           end)
   end
   self:connect_changed('v6_route', 'radvd')
   self:connect_changed('v6_nh', 'v6_rule')

   self.dhclient_ifnames = mst.set:new{}

   -- all  usable prefixes we have been given _some day_; 
   -- this is the domain of prefixes that we control, and therefore
   -- also remove addresses as neccessary if they spuriously show up
   -- (= usp removed, but lap still around)
   self.all_ipv6_binary_prefixes = mst.map:new{}

   self.skv:add_change_observer(self.f)

   -- get initial values (and notify changed if they're applicable)
   for k, v in pairs(self.skv:get_combined_state())
   do
      self:kv_changed(k, v)
   end
end

function pm:uninit()
   self.skv:remove_change_observer(self.f)
end

function pm:kv_changed(k, v)
   self:d('kv_changed', k, v)
   if k == elsa_pa.OSPF_USP_KEY
   then
      self.ospf_usp = v or {}
      
      -- reset caches
      self.ipv6_ospf_usp = nil
      self.external_if_set = nil

      -- update the all_ipv6_usp
      for i, v in ipairs(self:get_ipv6_usp())
      do
         local p = ipv6s.new_prefix_from_ascii(v.prefix)
         local bp = p:get_binary()
         self.all_ipv6_binary_prefixes[bp] = p
      end

      -- may be relevant to whether we want dhclient on the
      -- interface or not (border change?)
      self:queue('v4_dhclient')

      -- obviously v6 routes/rules also change
      self:queue('v6_route')
      self:queue('v6_rule')

      -- may need to change if we listen to RAs or not
      self:queue('v6_listen_ra')

   elseif k == elsa_pa.OSPF_IFLIST_KEY
   then
      self.ospf_iflist = v
      -- may need to start/stop DHCPv6 PD clients
      self:queue('v6_dhclient')
   elseif k == elsa_pa.OSPF_RID_KEY
   then
      --mst.a(v, 'empty rid not valid')
      self.rid = v
      self:queue('bird4')
   elseif k == elsa_pa.OSPF_LAP_KEY
   then
      -- reset cache
      self.ipv6_ospf_lap = nil

      self.ospf_lap = v or {}
      self:queue('v6_route')
      self:queue('v4_addr')
      -- depracation can cause addresses to become non-relevant
      -- => rewrite radvd.conf too (and dhcpd.conf - it may have
      -- been using address range which is now depracated)
      self:queue('radvd')
      self:queue('dhcpd')
      self:queue('bird4')

      if self.use_fakedhcpv6d
      then
         self:queue('fakedhcpv6d')
      end
   elseif k == elsa_pa.OSPF_IPV4_DNS_KEY
   then
      self.ospf_v4_dns = v or {}
      self:queue('dhcpd')
   elseif k == elsa_pa.OSPF_IPV4_DNS_SEARCH_KEY
   then
      self.ospf_v4_dns_search = v or {}
      self:queue('dhcpd')
   elseif k == elsa_pa.OSPF_DNS_KEY
   then
      self.ospf_dns = v or {}
      self:queue('dhcpd')
      self:queue('radvd')
      -- in theory fakedhcpv6d cares too, but in practise
      -- it has no state => next one will just have updated naming parameters
   elseif k == elsa_pa.OSPF_DNS_SEARCH_KEY
   then
      self.ospf_dns_search = v or {}
      self:queue('dhcpd')
      self:queue('radvd')
      -- in theory fakedhcpv6d cares too, but in practise
      -- it has no state => next one will just have updated naming parameters
   else
      -- if it looks like pd change, we may be also interested
      --if string.find(k, '^' .. elsa_pa.PD_KEY) then self:check_rules() end
   end
   self:schedule_run()
end

function pm:schedule_run()
   -- nop - someone else should e.g. use event loop here with
   -- 0-callback (to prevent duplicate actions on multiple skv changes
   -- in short period of time)
end

function pm:run()
   -- fixed order, sigh :) some day would be nice to replace this with
   -- something better (requires refactoring of unit tests too)
   for i, v in ipairs(self.handlers)
   do
      local o = self.h[v]
      -- conditionally run based on the queue() calls
      if o then o:maybe_run() end
   end

   self:d('run result', self.changes)
   local r = self.changes > 0 and self.changes
   self.changes = 0
   return r
end

-- this should be called every now and then
function pm:tick()
   self:d('tick')
   for i, v in ipairs(self.handlers)
   do
      local o = self.h[v]
      local v = o:tick()
      -- if it did return value based change mgmt, allow that too
      if v and v > 0 then o:changed() end
   end
   -- if there's pending changes, call run too
   if self.changes > 0
   then
      self:run()
   end
end

local function filter_ipv6(l)
   return mst.array_filter(l, function (usp)
                              local p = ipv6s.new_prefix_from_ascii(usp.prefix)
                              return not p:is_ipv4()
                              end)
end

function pm:get_ipv6_usp()
   if not self.ipv6_ospf_usp
   then
      self.ipv6_ospf_usp = filter_ipv6(self.ospf_usp)
   end
   return self.ipv6_ospf_usp
end

function pm:get_ipv6_lap()
   if not self.ipv6_ospf_lap
   then
      self.ipv6_ospf_lap = filter_ipv6(self.ospf_lap)
   end
   return self.ipv6_ospf_lap
end

function pm:repr_data()
   return mst.repr{ospf_lap=self.ospf_lap and #self.ospf_lap or 0}
end

function pm:get_external_if_set()
   -- get the set of external interfaces
   if not self.external_if_set
   then
      local usps = self.ospf_usp or {}
      local s = mst.set:new{}
      self.external_if_set = s
      mst.array_foreach(usps, 
                        function (usp)
                           if usp.ifname and not usp.nh
                           then
                              s:insert(usp.ifname)
                           end
                        end)
   end
   return self.external_if_set
end
