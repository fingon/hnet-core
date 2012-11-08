#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_handler_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 08:25:33 2012 mstenber
-- Last modified: Thu Nov  8 09:34:38 2012 mstenber
-- Edit time:     7 min
--

-- individual handler tests
require 'busted'
require 'dpm'
require 'pm_v6_nh'
require 'pm_v6_listen_ra'

module("pm_handler_spec", package.seeall)

describe("pm_v6_nh", function ()
            it("works", function ()
                  local pm = dpm.dpm:new{}
                  local o = pm_v6_nh.pm_v6_nh:new{pm=pm}
                  pm.ds:set_array{
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
                                     ]]},                      
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
                                     ]]},                      
                              }
                  o:tick()
                  o:tick()
                  mst.a(pm.nh:count() == 2, pm.nh)
                  pm.ds:check_used()
                   end)
end)

describe("pm_v6_listen_ra", function ()
            it("works", function ()
                  local pm = dpm.dpm:new{ipv6_usps={{ifname='eth0'},}}
                  local o = pm_v6_listen_ra.pm_v6_listen_ra:new{pm=pm}
                  pm.ds:set_array{
                     {'echo 2 > /proc/sys/net/ipv6/conf/eth0/accept_ra', ''},
                     {'echo 0 > /proc/sys/net/ipv6/conf/eth0/accept_ra_pinfo', ''},
                     {'echo 1 > /proc/sys/net/ipv6/conf/eth0/accept_ra_pinfo', ''},
                                 }
                  o:run()
                  -- make sure this is nop
                  o:run()
                  -- then get rid of ipv6_usps, should get rid of it
                  pm.ipv6_usps = {}
                  o:run()

                  pm.ds:check_used()
                   end)
end)
