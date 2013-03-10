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
-- Last modified: Sun Mar 10 17:03:59 2013 mstenber
-- Edit time:     89 min
--

-- individual handler tests
require 'busted'
require 'dpm'
require 'pm_v6_nh'
require 'pm_v6_listen_ra'
require 'pm_v6_route'
require 'pm_v6_dhclient'
require 'pm_v6_rule'
require 'pm_dnsmasq'
require 'pm_memory'
require 'pm_radvd'
require 'pm_fakedhcpv6d'
require 'dhcpv6codec'
require 'dshell'

module("pm_handler_spec", package.seeall)

local loop = ssloop.loop()

describe("pm_v6_rule", function ()
            local pm
            local o
            before_each(function ()
                           pm = dpm.dpm:new{}
                           o = pm_v6_rule.pm_v6_rule:new{pm=pm, 
                                                         port=12548}
                        end)
            it("works #rule", function ()
                  -- pretend something changed
                  o:queue()

                  -- make sure nothing happens without it being 'ready'
                  o:maybe_run()

                  pm.ds:set_array{
                     {'ip -6 rule', ''},
                     {'ip -6 rule add from dead::/56 table 1000 pref 1072', ''},
                     {'ip -6 route flush table 1000', ''},
                     {'ip -6 route add default via dead::1 dev eth0 table 1000', ''},
                     {'ip -6 route add default via dead::1 dev eth0 metric 123456'},
                     {'ip -6 rule add from all to dead::/56 table main pref 1000', ''},

                                 }

                  -- not used really, but just to pretend to be ready
                  pm.ospf_usp = true

                  -- really returned by get_ipv6_usp
                  pm.ipv6_usps = mst.array:new{
                     {nh='dead::1', ifname='eth0', prefix='dead::/56'},
                  }

                  mst.a(o:ready())
                  o:maybe_run()
                  
                  pm.ds:check_used()

                  -- ok, let's see what happens if we change only next hop
                  o:queue()
                  pm.ipv6_usps = mst.array:new{
                     {nh='dead::2', ifname='eth0', prefix='dead::/56'},
                  }
                  pm.ds:set_array{
                     {'ip -6 rule', [[
1000:	from all to dead::/56 lookup main 
1072:	from dead::/16 lookup 1000 
                                     ]]},
                     {'ip -6 rule add from dead::/56 table 1001 pref 1072',''},
                     {'ip -6 route flush table 1001', ''},
                     {'ip -6 route add default via dead::2 dev eth0 table 1001', ''},
                     {'ip -6 route add default via dead::2 dev eth0 metric 123456', ''},
                     {'ip -6 rule del from dead::/16 table 1000 pref 1072', ''},
                     {'ip -6 route del default via dead::1 dev eth0 metric 123456', ''},

                                 }
                  o:maybe_run()
                  pm.ds:check_used()


                   end)
             end)

describe("pm_fakedhcpv6d", function ()
            local pm
            local o
            local mcastlog
            local sentlog 
            before_each(function ()
                           mcastlog = {}
                           sentlog = {}
                           pm = dpm.dpm:new{}
                           o = pm_fakedhcpv6d.pm_fakedhcpv6d:new{pm=pm, 
                                                                 port=12348}
                           -- always-succeeding ops, that we just log
                           function o.mcj:try_multicast_op(ifname, is_join)
                              table.insert(mcastlog, {ifname, is_join})
                              return true
                           end
                           function o:sendto(data, dst, dstport)
                              table.insert(sentlog, {data, dst, dstport})
                           end
                        end)
            after_each(function ()
                          o:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #dhcpv6d", function ()
                  -- nothing should happen.. w/o ospf_lap
                  o:queue()
                  o:maybe_run()
                  mst.a(#mcastlog == 0)

                  -- after adding the lap, we should join the owner
                  -- interface, but not non-owner one
                  pm.ospf_lap = {
                     {ifname='eth0',
                      prefix='dead::/64',
                      owner=true,
                     },
                     {ifname='eth0',
                      prefix='beef::/64',
                      owner=true,
                      pclass=1,
                     },
                     {ifname='eth1',
                      prefix='cafe::/64',
                     },
                  }
                  pm.ospf_dns = {'dead::1'}
                  pm.ospf_dns_search = {'example.com', 'sometimes.ends.with.dot.'}
                  o:maybe_run()
                  local exp = {{'eth0', true}}
                  mst.a(mst.repr_equal(mcastlog, exp), 'non-expected mcast log', mcastlog)

                  -- let's synthesize a completely fake DHCPv6 message
                  -- and send it in - see what comes out. first info
                  -- request..
                  local m = {[1]={data="00030001827f5ea42778", 
                                  option=dhcpv6_const.O_CLIENTID}, 
                             type=dhcpv6_const.MT_INFORMATION_REQUEST, xid=42}
                  local mb = dhcpv6codec.dhcpv6_message:encode(m)
                  local client1 = 'fe80::2%eth1'
                  local client2 = 'fe80::1%eth0'
                  o:recvfrom(mb, client1, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 0, 'should receive no reply on invalid if')
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  
                  local r = dhcpv6codec.dhcpv6_message:decode(sentlog[1][1])
                  mst.a(r)
                  mst.a(r.type == dhcpv6_const.MT_REPLY)



                  -- first off, solicit w/o ORO =>
                  -- should get just status code
                  sentlog = {}
                  local m = {[1]={data="00030001827f5ea42778", 
                                  option=dhcpv6_const.O_CLIENTID}, 
                             [2]={iaid=123, option=3, t1=3600, t2=5400}, 
                             type=dhcpv6_const.MT_SOLICIT, xid=43}
                  local mb = dhcpv6codec.dhcpv6_message:encode(m)
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  local r = dhcpv6codec.dhcpv6_message:decode(sentlog[1][1])
                  mst.a(r)
                  mst.a(r.type == dhcpv6_const.MT_ADVERTISE)
                  function find_option(o, l)
                     for i, v in ipairs(l)
                     do
                        if v.option == o
                        then
                           return v
                        end
                     end
                  end
                  local na = find_option(dhcpv6_const.O_IA_NA, r)
                  mst.a(na, 'no ia_na in response')
                  local ia = find_option(dhcpv6_const.O_IAADDR, na)
                  mst.a(not ia, 'got addr without ORO?')
                  local sc = find_option(dhcpv6_const.O_STATUS_CODE, na)
                  mst.a(sc, 'no status code')
                  
                  -- then, solicit w/ ORO => should get proposed address
                  sentlog = {}
                  local m = {[1]={data="00030001827f5ea42778", 
                                  option=dhcpv6_const.O_CLIENTID}, 
                             [2]={iaid=123, option=3, t1=3600, t2=5400}, 
                             [3]={[1]=dhcpv6_const.O_PREFIX_CLASS,
                                  option=dhcpv6_const.O_ORO},
                             type=dhcpv6_const.MT_SOLICIT, xid=43}
                  local mb = dhcpv6codec.dhcpv6_message:encode(m)
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  local r = dhcpv6codec.dhcpv6_message:decode(sentlog[1][1])
                  mst.a(r)
                  mst.a(r.type == dhcpv6_const.MT_ADVERTISE)
                  function find_option(o, l)
                     for i, v in ipairs(l)
                     do
                        if v.option == o
                        then
                           return v
                        end
                     end
                  end
                  local na = find_option(dhcpv6_const.O_IA_NA, r)
                  mst.a(na, 'no ia_na in response')
                  local ia = find_option(dhcpv6_const.O_IAADDR, na)
                  mst.a(ia, 'no addr with ORO?')
                   end)
             end)

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
                     -- one case with explicit lifetimes
                     {ifname='eth0', prefix=dummy_prefix1, 
                      pref=pm.t+1234,
                      valid=pm.t+2345,
                     },
                     -- one with defaults
                     {ifname='eth1', prefix=dummy_prefix1, 
                     },
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
                  mst.a(string.find(s, "1234"), 'preferred missing')
                  mst.a(string.find(s, "2345"), 'valid missing')
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
