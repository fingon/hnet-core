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
-- Last modified: Fri Nov 16 13:10:31 2012 mstenber
-- Edit time:     20 min
--

-- individual handler tests
require 'busted'
require 'dpm'
require 'pm_v6_nh'
require 'pm_v6_listen_ra'
require 'pm_v6_route'
require 'pm_v6_dhclient'

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
                  -- we shouldn't do anything to interfaces with
                  -- explicit next hop managed by OSPFv3
                  local pm = dpm.dpm:new{ipv6_usps={{ifname='eth0'},
                                                    {ifname='eth1', nh='1'},
                                                   }}
                  local o = pm_v6_listen_ra.pm_v6_listen_ra:new{pm=pm}
                  pm.ds:set_array{
                     {'/usr/share/hnet/listen_ra_handler.sh start eth0', ''},
                     {'/usr/share/hnet/listen_ra_handler.sh stop eth0', ''},
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

describe("pm_v6_route", function ()
            it("works", function ()
                  -- make sure that in a list with 3 prefixes, middle
                  -- one not deprecated, we get the middle one..
                  -- (found a bug, code review is fun(?))
                  local pm = dpm.dpm:new{ipv6_laps={
                                            {depracate=true,
                                             ifname='eth2',
                                             prefix='beef::/64'},
                                            {prefix='beef::/64',
                                             ifname='eth0',
                                            },
                                            {depracate=true,
                                             ifname='eth1',
                                             prefix='beef::/64'},

                                                   }
                                        }
                  local o = pm_v6_route.pm_v6_route:new{pm=pm}
                  pm.ds:set_array{
                     {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary", ''},
                     {'ifconfig eth0 | grep HWaddr', 
                      'eth0      Link encap:Ethernet  HWaddr 00:1c:42:a7:f1:d9  '},
                     {'ip -6 addr add beef::21c:42ff:fea7:f1d9/64 dev eth0', ''},

                                 }
                  o:run()
                  pm.ds:check_used()
                  
                   end)
end)


describe("pm_v6_dhclient", function ()
            it("works", function ()
                  local pm = dpm.dpm:new{ospf_iflist={"eth0"}}
                  local o = pm_v6_dhclient.pm_v6_dhclient:new{pm=pm}
                  pm.ds:set_array{
                                 {'ls -1 /var/run', ''},
{'/usr/share/hnet/dhclient6_handler.sh start eth0 /var/run/pm-pid-dhclient6-eth0', ''},
                                 {'ls -1 /var/run', ''},
{'/usr/share/hnet/dhclient6_handler.sh start eth0 /var/run/pm-pid-dhclient6-eth0', ''},
                                 {'ls -1 /var/run', 'pm-pid-dhclient6-eth0'},
                                 {'ls -1 /var/run', 'pm-pid-dhclient6-eth0'},
}

                  o:run()
                  -- 2nd start - pid file disappeared - restart
                  o:run()

                  -- 3rd start - pid file exists - should be nop
                  o:run()

                  -- 4th start - make sure that getting rid of eth0
                  -- will still not remove the dhclient6 (we have
                  -- 'faith' that it will eventually pop back)
                  pm.ospf_iflist = nil
                  o:run()

                  pm.ds:check_used()

                   end)
end)
