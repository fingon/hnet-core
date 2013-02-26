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
-- Last modified: Tue Feb 26 17:58:43 2013 mstenber
-- Edit time:     42 min
--

-- individual handler tests
require 'busted'
require 'dpm'
require 'pm_v6_nh'
require 'pm_v6_listen_ra'
require 'pm_v6_route'
require 'pm_v6_dhclient'
require 'pm_dnsmasq'
require 'pm_memory'
require 'pm_radvd'

module("pm_handler_spec", package.seeall)

describe("pm_radvd", function ()
            it("works", function ()
                  local dummy_conf = '/tmp/dummy-radvd.conf'
                  local dummy_prefix1 = 'dead::/64'
                  local dummy_prefix2 = 'beef::/64'
                  local pm = dpm.dpm:new{radvd_conf_filename=dummy_conf}
                  local o = pm_radvd.pm_radvd:new{pm=pm}

                  -- make sure nothing happens if it isn't ready yet
                  pm.ds:set_array{}
                  o:queue()
                  o:maybe_run()
                  pm.ds:check_used()

                  -- then, do something for real; provide config
                  -- for one interface (eth0) with two prefixes - one
                  -- with pclass, one without; as a result, we should create
                  -- a config file which has just the non-pclass prefix
                  -- (we shouldn't advertise pclass prefixes)
                  pm.ospf_lap = {
                     {ifname='eth0', prefix=dummy_prefix1},
                     {ifname='eth0', pclass=1, prefix=dummy_prefix2},
                     }
                  pm.ds:set_array{
                     {'killall -9 radvd'},
                     {'rm -f /var/run/radvd.pid'},
                     {'radvd -C ' .. dummy_conf},
                                 }
                  o:queue()
                  o:maybe_run()
                  pm.ds:check_used()

                  local s = mst.read_filename_to_string(dummy_conf)
                  mst.a(string.find(s, dummy_prefix1), 'first prefix missing')
                  mst.a(not string.find(s, dummy_prefix2), 
                        'second prefix present (but should not be, pclass)')

                        end)
             end)

describe("pm_v6_nh", function ()
            it("works", function ()
                  local pm = dpm.dpm:new{}
                  local o = pm_v6_nh.pm_v6_nh:new{pm=pm}
                  pm.ds:set_array{
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.5 dev eth0 metric 123456
                                     ]]},                      
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.5 dev eth0 metric 123456
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
                  -- explicit next hop managed by OSPFv3,
                  -- or internal interfaces (eth2 not external)
                  local pm = dpm.dpm:new{ipv6_usps={{ifname='eth0'},
                                                    {ifname='eth1', nh='1'},
                                                    {ifname='eth2'},
                                                   },
                                         external_ifs={eth0=true},
                                        }
                  local o = pm_v6_listen_ra.pm_v6_listen_ra:new{pm=pm}
                  pm.ds:set_array{
                     {'/usr/share/hnet/listen_ra_handler.sh start eth0', ''},
                     {'/usr/share/hnet/listen_ra_handler.sh stop eth0', ''},
                                 }
                  o:run()
                  -- make sure this is nop
                  o:run()
                  -- then get rid of external interfaces -> should disappear
                  pm.external_ifs={}
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

describe("pm_dnsmasq", function ()
            local conf = '/tmp/t-dnsmasq.conf'
            it("works", function ()
                  local pm = dpm.dpm:new{ospf_lap={{ifname='eth0',
                                                    prefix='dead::/64',
                                                    owner=true},
                                                   {ifname='eth0',
                                                    prefix='beef::/64',
                                                    owner=true,
                                                    depracate=true},
                                                   {ifname='eth0',
                                                    prefix='10.1.42.0/24',
                                                    owner=true},
                                                  },
                                         dnsmasq_conf_filename=conf,
                                        }
                  local o = pm_dnsmasq.pm_dnsmasq:new{pm=pm}
                  pm.ds:set_array{
                     {'/usr/share/hnet/dnsmasq_handler.sh start /tmp/t-dnsmasq.conf', ''},
                     {'/usr/share/hnet/dnsmasq_handler.sh reload /tmp/t-dnsmasq.conf', ''},
                     {'/usr/share/hnet/dnsmasq_handler.sh stop', ''},
                                 }

                  -- first off, it should start
                  o:run()

                  local s = mst.read_filename_to_string(conf)
                  mst.a(string.find(s, '10.1.42.6'), 'no valid ipv4 address?')
                  mst.a(string.find(s, 'depre'), 'no depracated range')


                  -- 2nd run should do nothing, as state hasn't changed
                  o:run()

                  -- then, we change state => should get called with reload
                  pm.ospf_lap = {pm.ospf_lap[1]}
                  o:run()

                  -- v4 address should be gone as we zapped it
                  local s = mst.read_filename_to_string(conf)
                  mst.a(not string.find(s, '10.1.42.6'), 'valid ipv4 address?')

                  -- get rid of state, make sure cleanup kills dnsmasq
                  pm.ospf_lap = nil
                  o:run()

                  pm.ds:check_used()


                   end)
end)

describe("pm_memory", function ()
            it("does nothing ;)", function ()
                  local pm = dpm.dpm:new{}
                  local o = pm_memory.pm_memory:new{pm=pm}
                  -- run twice, just for fun
                  o:run()
                  o:run()
                  -- tick twice, just for fun
                  o:tick()
                  o:tick()

                   end)
end)
