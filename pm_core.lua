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
-- Last modified: Mon Oct  7 14:46:38 2013 mstenber
-- Edit time:     630 min
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
require 'mst_eventful'
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

local function filter_ipv6(l)
   return mst.array_filter(l, function (usp)
                              local p = ipv6s.new_prefix_from_ascii(usp.prefix)
                              return not p:is_ipv4()
                              end)
end

usp_blob = mst.create_class{class='usp_blob'}

function usp_blob:get_external_if_set()
   -- get the set of external interfaces
   if not self.external_if_set
   then
      local s = mst.set:new{}
      self.external_if_set = s
      mst.array_foreach(self, 
                        function (usp)
                           if usp.ifname and not usp.nh
                           then
                              s:insert(usp.ifname)
                           end
                        end)
   end
   return self.external_if_set
end

function usp_blob:get_ipv6()
   if not self.ipv6
   then
      self.ipv6 = filter_ipv6(self)
   end
   return self.ipv6
end

lap_blob = mst.create_class{class='lap_blob'}

function lap_blob:get_ipv6()
   if not self.ipv6
   then
      self.ipv6 = filter_ipv6(self)
   end
   return self.ipv6
end

local _e = mst_eventful.eventful

pm = _e:new_subclass{class='pm',
                     mandatory={'skv', 'shell'},
                     events={'usp_changed', -- usp info blob
                        'lap_changed', -- lap info blob
                        'skv_changed', -- key, value (some other one)
                        --'config_changed', -- config info blob

                        -- provided by pm_v6_route
                        'v6_addr_changed', -- (no content?)

                        -- provided by pm_v6_nh
                        'v6_nh_changed', -- v6_nh dict

                        -- provided by pm_netifd_interface
                        -- (openwrt-only)
                        'network_interface_changed', -- network.interface dump
                     },
                     time=function (...)
                        return os.time()
                     end}

function pm:init()
   _e.init(self)
   self.changes = 0
   local config = self.config or {}
   self.f = function (k, v) self:kv_changed(k, v) end
   self.h = {}

   for k, v in pairs(DEFAULT_FILENAMES)
   do
      config[k] = config[k] or CONF_PREFIX .. v
   end
   -- !!! These are in MOSTLY alphabetical order for the time being.
   -- DO NOT CHANGE THE ORDER (at least without fixing the pm_core_spec as well)
   if not self.handlers
   then
      self.handlers = mst.array:new{'bird4'}
      if config.openwrt
      then
         -- we can keep using bird4 I suppose like we did, although
         -- it's not pretty

         self.handlers:extend{
            -- for debugging purposes
            'memory',
            'led',

            -- the input which parses to network.interface dump
            'netifd_pull',

            -- the output which calls network.interface update mechanism
            'netifd_push',

            -- and firewall configuration script
            'netifd_firewall',
                             }
      else
         -- fallback - old list of handlers
         if not config.use_dnsmasq
         then
            self.handlers:insert('dhcpd')
         end
         self.handlers:extend{
            'v4_addr',
            'v4_dhclient',
            'v6_dhclient',
            'v6_listen_ra',
            'v6_nh',
            'v6_route',
            'v6_rule',
                             }
         if not config.use_dnsmasq
         then
            self.handlers:insert('radvd')
            -- radvd depends on v6_route => it is last
         end
         self.handlers:extend{
            -- this doesn't matter, it just has tick
            'memory',
            -- this controls the leds
            'led',
                             }
         if config.use_dnsmasq
         then
            self.handlers:insert('dnsmasq')
         end
         if config.use_fakedhcpv6d
         then
            -- dhcpd will take care of v4 only, and v6 IA_NA replies will be
            -- provided by fakedhcpv6d
            self.handlers:insert('fakedhcpv6d')
         end
      end
   end

   self.skv:set('pm-handlers', self.handlers)

   for i, v in ipairs(self.handlers)
   do
      local v2 = 'pm_' .. v
      local m = require(v2)
      local o = m[v2]:new{_pm=self, config=config}
      self.h[v] = o
      -- make sure it updates self.changes if it changes
      o:connect(o.changed, function ()
                   self.changes = self.changes + 1
                           end)
   end

   -- post-init activities

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
   for k, v in pairs(self.h)
   do
      v:done()
   end
   self.skv:remove_change_observer(self.f)
end

function pm:kv_changed(k, v)
   self:d('kv_changed', k, v)
   if k == elsa_pa.OSPF_USP_KEY
   then
      v = mst.table_deep_copy(v)
      setmetatable(v, nil)
      local usp = usp_blob:new(v)
      
      -- update the all_ipv6_usp
      for i, v in ipairs(usp:get_ipv6())
      do
         local p = ipv6s.new_prefix_from_ascii(v.prefix)
         local bp = p:get_binary()
         self.all_ipv6_binary_prefixes[bp] = p
      end

      self.usp_changed(usp)
   elseif k == elsa_pa.OSPF_LAP_KEY
   then
      v = mst.table_deep_copy(v)
      setmetatable(v, nil)
      local lap = lap_blob:new(v)
      self.lap_changed(lap)
   else
      self.skv_changed(k, v)
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
      local v = o:maybe_tick()
      -- if it did return value based change mgmt, allow that too
      if v and v > 0 then o:changed() end
   end
   -- if there's pending changes, call run too
   if self.changes > 0
   then
      self:run()
   end
end

function pm:repr_data()
   return mst.repr{ospf_lap=self.ospf_lap and #self.ospf_lap or 0}
end

