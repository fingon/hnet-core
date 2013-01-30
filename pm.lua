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
-- Last modified: Wed Jan 30 16:25:03 2013 mstenber
-- Edit time:     27 min
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
require 'pm_core'
require 'skv'
require 'ssloop'

-- how often we run stuff that is bound to run every 'tick'?  (these
-- may involve e.g. shell commands to check system state, so it should
-- not be too short)
DEFAULT_TICK_INTERVAL=10

local loop = ssloop.loop()

_TEST = false

function create_cli()
   local cli = require "cliargs"

   cli:set_name('pm.lua')
   cli:add_flag("-m, --dnsmasq", "use dnsmasq instead of ISC dhcpd + radvd")
   cli:add_flag('--disable_ula', 'disable ULA generation altogether')
   cli:add_flag('--disable_always_ula', 'disable ULAs if global addresses present')
   cli:add_flag('--disable_ipv4', 'disable generation of NATted IPv4 sub-prefixes')
   return cli
end


local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

mst.d('initializing skv')
local s = skv.skv:new{long_lived=true}

-- set up the pa configuration
local config = {}
for _, k in ipairs{'disable_ula', 'disable_always_ula', 'disable_ipv4'}
do
   if args[k]
   then
      config[k] = args[k]
   end
end
if mst.table_count(config)
then
   s:set(elsa_pa.PA_CONFIG_SKV_KEY, config)
end

mst.d('initializing pm')
local pm = pm_core.pm:new{shell=mst.execute_to_string, skv=s,
                          radvd='radvd -m logfile',
                          use_dnsmasq=args.m,
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

function schedule_next_tick()
   local t
   t = loop:new_timeout_delta(DEFAULT_TICK_INTERVAL,
                              function ()
                                 -- call tick
                                 pm:tick()
                                 
                                 -- get rid of the timeout
                                 t:done()

                                 schedule_next_tick()
                              end):start()
end

mst.d('entering event loop')
schedule_next_tick()
loop:loop()
