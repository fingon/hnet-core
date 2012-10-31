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
-- Last modified: Wed Oct 31 21:36:15 2012 mstenber
-- Edit time:     10 min
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

local loop = ssloop.loop()

-- XXX - option processing

mst.d('initializing skv')
local s = skv.skv:new{long_lived=true}
mst.d('initializing pm')
local pm = pm_core.pm:new{shell=mst.execute_to_string, skv=s,
                          radvd='radvd -m logfile',
                          radvd_conf_filename='/etc/pm-radvd.conf',
                          dhcpd_conf_filename='/etc/pm-dhcpd.conf',
                          dhcpd6_conf_filename='/etc/pm-dhcpd6.conf',
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

mst.d('entering event loop')
loop:loop()
