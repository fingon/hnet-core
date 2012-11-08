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
-- Last modified: Thu Nov  8 08:23:54 2012 mstenber
-- Edit time:     520 min
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

pm = mst.create_class{class='pm', mandatory={'skv', 'shell', 
                                             'radvd_conf_filename',
                                             'dhcpd_conf_filename',
                                             'dhcpd6_conf_filename',
                                            }}

function pm:connect_changed(srcname, dstname)
   local h = self.h[srcname]
   if not h
   then
      return
   end
   local h2 = self.h[dstname]
   if not h2
   then
      return
   end
   h:connect_method(h.changed, h2, h2.queue)
end

function pm:queue(name)
   self:a(self.h)
   local o = self.h[name]
   if not o
   then
      return
   end
   if o:queue()
   then
      self:d('queued', o)
   end
end


local _handlers = {'v6_route',
                   'v4_dhclient',
                   'bird4',
                   'v6_rule',
                   'v4_addr',
                   'radvd',
                   'dhcpd',
                   'v6_nh',
}

function pm:init()
   self.changes = 0
   self.f = function (k, v) self:kv_changed(k, v) end
   self.h = {}

   -- shared datastructures
   self.if_table = linux_if.if_table:new{shell=self.shell} 
   -- IPv6 next hops - ifname => nh-list
   self.nh = mst.multimap:new{}

   for i, v in ipairs(_handlers)
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
      
      -- reset cache
      self.ipv6_ospf_usp = nil

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
   elseif k == elsa_pa.OSPF_RID_KEY
   then
      --mst.a(v, 'empty rid not valid')
      self.rid = v
      self:queue('bird4')
   elseif k == elsa_pa.OSPF_LAP_KEY
   then
      self.ospf_lap = v or {}
      self:queue('v6_route')
      self:queue('v4_addr')
      -- depracation can cause addresses to become non-relevant
      -- => rewrite radvd.conf too (and dhcpd.conf - it may have
      -- been using address range which is now depracated)
      self:queue('radvd')
      self:queue('dhcpd')
      self:queue('bird4')
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
   elseif k == elsa_pa.OSPF_DNS_SEARCH_KEY
   then
      self.ospf_dns_search = v or {}
      self:queue('dhcpd')
      self:queue('radvd')
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
   -- fixed order, sigh :)
   -- XXX - replace this with something better
   -- (requires refactoring of unit tests too)
   for i, v in ipairs(_handlers)
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
   for i, v in ipairs(_handlers)
   do
      local o = self.h[v]
      o:tick()
   end
   -- if there's pending changes, call run too
   if self.changes > 0
   then
      self:run()
   end
end

function pm:get_ipv6_usp()
   if not self.ipv6_ospf_usp
   then
      self.ipv6_ospf_usp = 
         mst.array_filter(self.ospf_usp, function (usp)
                             local p = ipv6s.new_prefix_from_ascii(usp.prefix)
                             return not p:is_ipv4()
                                         end)
   end
   return self.ipv6_ospf_usp
end

function pm:repr_data()
   return mst.repr{ospf_lap=self.ospf_lap and #self.ospf_lap or 0}
end

