#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Oct  4 19:38:48 2012 mstenber
-- Last modified: Mon Sep 30 17:33:52 2013 mstenber
-- Edit time:     44 min
--

-- 'prefix manager' (name still temporary)
--
-- it is responsible for keeping the skv state and system state in
-- sync, by listening to skv change notifications, and attempting to
-- make the local state reflect skv state

-- (add/remove interface IPv6 addresses, and possibly rewrite
-- radvd.conf/dhcp/... configurations and kick them in the head etc
-- later on)

require 'mst'
require 'mst_cliargs'
require 'pm_core'
require 'skv'
require 'ssloop'
require 'skvtool_core'

-- how often we run stuff that is bound to run every 'tick'?  (these
-- may involve e.g. shell commands to check system state, so it should
-- not be too short)
DEFAULT_TICK_INTERVAL=10

local loop = ssloop.loop()

_TEST = false

local args = mst_cliargs.parse{
   options={
      {name='fakedhcpv6d',
       desc="use fakedhcpv6d to respond to DHCPv6 queries",
       flag=1},
      {name='dnsmasq', alias='m',
       desc="use dnsmasq instead of ISC dhcpd + radvd",
       flag=1},
      {alias='h', name='use_hp_ospf', 
       desc='use hybrid DNS proxy instead of dnsmasq for DNS (requires --dnsmasq to be present too)',
       flag=1},
      {name=pa.CONFIG_DISABLE_ULA, 
       desc='disable ULA generation altogether',
       flag=1},
      {name=pa.CONFIG_DISABLE_ALWAYS_ULA, 
       desc='disable ULAs if global addresses present',
       flag=1},
      {name=pa.CONFIG_DISABLE_IPV4, 
       desc='disable generation of NATted IPv4 sub-prefixes',
       flag=1},
      {value='skv', 
       desc='SKV values to set (key=value style)', 
       max=10},
   }
                              }

mst.d('initializing skv')
local s = skv.skv:new{long_lived=true}
if args.skv 
then
   -- handle setting of key=values as appropriate
   skvtool_core.stc:new{skv=s, disable_wait=true}:process_keys(args.skv)
end

-- set up the pa configuration
local config = {}
for _, k in ipairs(pa.CONFIGS)
do
   if args[k]
   then
      config[k] = args[k]
   end
end

-- pa_config means that prefix assignment should even run; without it,
-- nothing happens. so we have to send it, even if it's empty (this is
-- meaningful only on very constrained machines).
s:set(elsa_pa.PA_CONFIG_SKV_KEY, config)

mst.d('initializing pm')
local pm = pm_core.pm:new{shell=mst.execute_to_string, skv=s,
                          config={radvd='radvd -m logfile',
                          },
                          use_dnsmasq=args.dnsmasq,
                          use_fakedhcpv6d=args.fakedhcpv6d,
                          use_hp_ospf=args.use_hp_ospf,
                         }

function pm:schedule_run()
   local t
   t = loop:new_timeout_delta(0,
                              function ()
                                 -- call run
                                 pm:run()
                                 
                                 -- get rid of the timeout
                                 t:done()
                              end):start()
   
end

ssloop.repeat_every_timedelta(DEFAULT_TICK_INTERVAL,
                              function ()
                                 -- call tick
                                 pm:tick()
                              end)

mst.d('entering event loop')
loop:loop()
