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
-- Last modified: Fri Oct  4 14:23:44 2013 mstenber
-- Edit time:     262 min
--

-- individual handler tests
require 'busted'
require 'dpm'
require 'dhcpv6_codec'
require 'dshell'
require 'mst_test'

module("pm_handler_spec", package.seeall)

local loop = ssloop.loop()

describe("pm_led #led", function ()
            local pm
            local o
            before_each(function ()
                           pm = dpm.dpm:new{handlers={'led'}}
                           o = pm.h.led
                        end)
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #led", function ()
                  pm.ds:set_array{
                     {'/usr/share/hnet/led_handler.sh pd 0', ''},
                     {'/usr/share/hnet/led_handler.sh global 0', ''},
                                 }
                  mst.a(not o:ready())

                  -- ok, give it usp + lap to chew on
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, {})
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, {})
                  mst.a(o:ready())

                  o:maybe_run()
                  pm.ds:check_used()
                  
                  -- second run should do nothing
                  o:maybe_run()

                  -- had-pd indicator should work
                  pm.skv:set(elsa_pa.PD_SKVPREFIX .. "asdf",
                             {
                                {prefix='dead::1'},
                             })
                  pm.ds:set_array{
                     {'/usr/share/hnet/led_handler.sh pd 1', ''},
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  -- and global indicator
                  mst.a(not o.queued)
                  pm.skv:set(elsa_pa.OSPF_USP_KEY,
                             {{nh='dead::1', ifname='eth0', prefix='dead::/56'}}
                            )
                  mst.a(o.queued)
                  pm.ds:set_array{
                     {'/usr/share/hnet/led_handler.sh global 1', ''},
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  
                        end)
                        end)

describe("pm_v6_rule", function ()
            local pm
            local o
            before_each(function ()
                           pm = dpm.dpm:new{handlers={'v6_rule'}}
                           o = pm.h.v6_rule
                        end)
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
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
                     --{'ip -6 route add default via dead::1 dev eth0 metric 123456'}, (applicable only if usp.rid ~= self.rid
                     {'ip -6 rule add from all to dead::/56 table main pref 1000', ''},

                                 }

                  pm.skv:set(elsa_pa.OSPF_USP_KEY, 
                             {{nh='dead::1', ifname='eth0', prefix='dead::/56'}})
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, {})

                  mst.a(o:ready(), 'not ready')
                  o:maybe_run()
                  
                  pm.ds:check_used()

                  -- ok, let's see what happens if we change only next hop
                  mst.d('- changing next hop')

                  o:queue()
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, 
                             {{nh='dead::2', ifname='eth0', prefix='dead::/56'}})
                  pm.ds:set_array{
                     {'ip -6 rule', [[
1000:	from all to dead::/56 lookup main
1072:	from dead::/56 lookup 1000
                                     ]]},
                     -- {'ip -6 route del default via dead::1 dev eth0 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                     {'ip -6 route flush table 1000', ''},
                     {'ip -6 route add default via dead::2 dev eth0 table 1000', ''},
                     -- {'ip -6 route add default via dead::2 dev eth0 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  -- and then flap ifname x3 (just to make sure changes continue happening)

                  -- 1)
                  mst.d('- flapping ifname (1)')
                  o:queue()
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, 
                             {
                                {nh='dead::2', ifname='eth1', prefix='dead::/56'}})
                  pm.ds:set_array{
                     {'ip -6 rule', [[
                                        1000:	from all to dead::/56 lookup main
                                        1072:	from dead::/56 lookup 1000
                                     ]]},
                     --{'ip -6 route del default via dead::2 dev eth0 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                     {'ip -6 route flush table 1000', ''},
                     {'ip -6 route add default via dead::2 dev eth1 table 1000', ''},
                     --{'ip -6 route add default via dead::2 dev eth1 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  -- 2)
                  mst.d('- flapping ifname (2)')
                  o:queue()
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, 
                             {{nh='dead::2', ifname='eth0', prefix='dead::/56'}})
                  pm.ds:set_array{
                     {'ip -6 rule', [[
                                        1000:	from all to dead::/56 lookup main
                                        1072:	from dead::/56 lookup 1000
                                     ]]},
                     --{'ip -6 route del default via dead::2 dev eth0 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                     {'ip -6 route flush table 1000', ''},
                     {'ip -6 route add default via dead::2 dev eth0 table 1000', ''},
                     --{'ip -6 route add default via dead::2 dev eth1 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  -- 3)
                  mst.d('- flapping ifname (3)')
                  o:queue()
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, 
                             {{nh='dead::2', ifname='eth1', prefix='dead::/56'}})
                  pm.ds:set_array{
                     {'ip -6 rule', [[
                                        1000:	from all to dead::/56 lookup main
                                        1072:	from dead::/56 lookup 1000
                                     ]]},
                     --{'ip -6 route del default via dead::2 dev eth0 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                     {'ip -6 route flush table 1000', ''},
                     {'ip -6 route add default via dead::2 dev eth1 table 1000', ''},
                     --{'ip -6 route add default via dead::2 dev eth1 metric 123456', ''}, (applicably only if usp.rid ~= self.rid)
                                 }
                  o:maybe_run()
                  pm.ds:check_used()

                  -- 4) make sure nop = nop
                  mst.d('- nop')
                  o:queue()
                  pm.ds:set_array{
                     {'ip -6 rule', [[
                                        1000:	from all to dead::/56 lookup main
                                        1072:	from dead::/56 lookup 1000
                                     ]]},
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
                           pm = dpm.dpm:new{handlers={'fakedhcpv6d'},
                                            config={dhcpv6_port=12348}}
                           o = pm.h.fakedhcpv6d
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
                          pm:done()
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
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, {})
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, 
                             {
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
                             })
                  pm.skv:set(elsa_pa.OSPF_DNS_KEY,{'dead::1'})
                  pm.skv:set(elsa_pa.OSPF_DNS_SEARCH_KEY,
                             {'example.com', 'sometimes.ends.with.dot.'})
                  o:maybe_run()
                  local exp = {{'eth0', true}}
                  mst_test.assert_repr_equal(mcastlog, exp)

                  -- let's synthesize a completely fake DHCPv6 message
                  -- and send it in - see what comes out. first info
                  -- request..
                  local m = {[1]={data="00030001827f5ea42778", 
                                  option=dhcpv6_const.O_CLIENTID}, 
                             type=dhcpv6_const.MT_INFORMATION_REQUEST, xid=42}
                  local mb = dhcpv6_codec.dhcpv6_message:encode(m)
                  local client1 = 'fe80::2%eth1'
                  local client2 = 'fe80::1%eth0'
                  o:recvfrom(mb, client1, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 0, 'should receive no reply on invalid if')
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  
                  local r = dhcpv6_codec.dhcpv6_message:decode(sentlog[1][1])
                  mst.a(r)
                  mst.a(r.type == dhcpv6_const.MT_REPLY)



                  -- first off, solicit w/o ORO =>
                  -- should get just status code
                  sentlog = {}
                  local m = {[1]={data="00030001827f5ea42778", 
                                  option=dhcpv6_const.O_CLIENTID}, 
                             [2]={iaid=123, option=3, t1=3600, t2=5400}, 
                             type=dhcpv6_const.MT_SOLICIT, xid=43}
                  local mb = dhcpv6_codec.dhcpv6_message:encode(m)
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  local r = dhcpv6_codec.dhcpv6_message:decode(sentlog[1][1])
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
                  local mb = dhcpv6_codec.dhcpv6_message:encode(m)
                  o:recvfrom(mb, client2, dhcpv6_const.CLIENT_PORT)
                  mst.a(#sentlog == 1, 'no reply?', sentlog)
                  local r = dhcpv6_codec.dhcpv6_message:decode(sentlog[1][1])
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
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #radvd", function ()
                  local dummy_conf = '/tmp/dummy-radvd.conf'
                  local dummy_prefix1 = 'dead::/64'
                  local dummy_prefix2 = 'beef::/64'
                  pm =  dpm.dpm:new{config={radvd_conf_filename=dummy_conf},
                                         handlers={'radvd'}}
                  local o = pm.h.radvd

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

                  local explicit_ok_lap = {
                     -- one case with explicit lifetimes
                     {ifname='eth0', prefix=dummy_prefix1, 
                      pref=pm.t+1234,
                      valid=pm.t+2345,
                     },
                     -- one with defaults (but with pclass)
                     {ifname='eth0', pclass=1, prefix=dummy_prefix2},
                  }

                  local invalid1_lap = {
                     {ifname='eth1', prefix=dummy_prefix1},
                  }

                  local invalid2_lap = {
                     {ifname='eth1', prefix=dummy_prefix1, 
                      valid=123456, pref=-123},
                  }
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, {})
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, explicit_ok_lap)
                  local restart_array = {
                     {'killall -9 radvd'},
                     {'rm -f /var/run/radvd.pid'},
                     {'radvd -C ' .. dummy_conf},
                  }
                  pm.ds:set_array(restart_array)
                  o:queue()
                  o:maybe_run()
                  pm.ds:check_used()

                  local s = mst.read_filename_to_string(dummy_conf)
                  mst.a(string.find(s, dummy_prefix1), 'first prefix missing')
                  mst.a(string.find(s, "1234"), 'preferred missing')
                  mst.a(string.find(s, "2345"), 'valid missing')
                  mst.a(string.find(s, "Decrement"), 'decrement missing')
                  mst.a(not string.find(s, dummy_prefix2), 
                        'second prefix present (but should not be, pclass)')
                  
                  -- try #2
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, invalid1_lap)
                  pm.ds:set_array(restart_array)
                  o:run()
                  local s = mst.read_filename_to_string(dummy_conf)
                  mst.a(string.find(s, dummy_prefix1), 'first prefix missing')
                  mst.a(not string.find(s, "Decrement"), 'decrement found')
                  mst.a(string.find(s, pm_radvd.DEFAULT_PREFERRED_LIFETIME),
                        'no default preferred lifetime found')
                  mst.a(string.find(s, pm_radvd.DEFAULT_VALID_LIFETIME),
                        'no default valid lifetime found')
                  
                  -- try #3
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, invalid2_lap)
                  pm.ds:set_array(restart_array)
                  o:run()
                  local s = mst.read_filename_to_string(dummy_conf)
                  mst.a(string.find(s, dummy_prefix1), 'first prefix missing')
                  mst.a(not string.find(s, "Decrement"), 'decrement found')
                  mst.a(string.find(s, pm_radvd.DEFAULT_PREFERRED_LIFETIME),
                        'no default preferred lifetime found')
                  mst.a(not string.find(s, pm_radvd.DEFAULT_VALID_LIFETIME),
                        'default valid lifetime found')


                        end)

                     end)

describe("pm_v6_nh", function ()
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #v6_nh", function ()
                  pm =  dpm.dpm:new{handlers={'v6_nh'}}
                  local o = pm.h.v6_nh
                  -- make sure that it does NOTHING without external
                  -- USP present
                  o:maybe_tick()
                  pm.ds:check_used()

                  -- ifname but no nh == external
                  -- ifname + nh == OSPF-routed internal
                  --pm.ospf_usp = {{ifname='eth0'}}

                  -- however, dpm doesn't do the real API -> have to just set the external_ifs.
                  pm.skv:set(elsa_pa.OSPF_USP_KEY,
                             {{prefix='dead::/16', ifname='eth0'}})

                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, {})

                  pm.ds:set_array{
                     {'ip -6 route',[[
                                        1.2.3.4 via 2.3.4.5 dev eth0
                                        default via 1.2.3.4 dev eth0
                                        default via 1.2.3.4 dev eth0
                                        default via 1.2.3.4 dev eth1
                                        default via 1.2.3.5 dev eth0 metric 123456
                                     ]]},                      
                     {'ip -6 route',[[
                                        1.2.3.4 via 2.3.4.5 dev eth0
                                        default via 1.2.3.4 dev eth0
                                        default via 1.2.3.4 dev eth0
                                        default via 1.2.3.4 dev eth1
                                        default via 1.2.3.5 dev eth0 metric 123456
                                     ]]},                      
                                 }
                  o:maybe_tick()
                  o:maybe_tick()
                  pm.ds:check_used()
                  mst.a(o.nh, 'no o.nh')
                  mst.a(o.nh.count, 'no count?!?', o.nh)
                  mst.a(o.nh:count() == 2, o.nh)
                            end)
                     end)

describe("pm_v6_listen_ra", function ()
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #v6_listen_ra", function ()
                  -- we shouldn't do anything to interfaces with
                  -- explicit next hop managed by OSPFv3,
                  -- or internal interfaces (eth2 not external)
                  pm =  dpm.dpm:new{handler='v6_listen_ra'}
                  local o = pm.h.v6_listen_ra
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, {})
                  pm.skv:set(elsa_pa.OSPF_USP_KEY,
                             {{ifname='eth0', prefix='dead::/16'},
                              {ifname='eth1', prefix='dead::/16', nh='1'},
                              --{ifname='eth2', prefix='dead::/16'},
                             })
                  pm.ds:set_array{
                     {'/usr/share/hnet/listen_ra_handler.sh start eth0', ''},
                     {'/usr/share/hnet/listen_ra_handler.sh stop eth0', ''},
                                 }
                  o:run()
                  -- make sure this is nop
                  o:run()
                  -- then get rid of external interfaces -> should disappear
                  pm.skv:set(elsa_pa.OSPF_USP_KEY,
                             {--{{ifname='eth0', prefix='dead::/16'},
                              {ifname='eth1', prefix='dead::/16', nh='1'},
                              --{ifname='eth2', prefix='dead::/16'},
                             })
                  o:run()

                  pm.ds:check_used()
                        end)
                            end)

describe("pm_v6_route", function ()
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #v6_route", function ()
                  -- make sure that in a list with 3 prefixes, middle
                  -- one not deprecated, we get the middle one..
                  -- (found a bug, code review is fun(?))
                  pm = dpm.dpm:new{handlers={'v6_route'}}
                  local o = pm.h.v6_route
                  pm.skv:set(elsa_pa.OSPF_USP_KEY, {})
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, 
                             {
                                {depracate=true,
                                 ifname='eth2',
                                 prefix='beef::/64'},
                                {prefix='beef::/64',
                                 ifname='eth0',
                                 address='beef::21c:42ff:fea7:f1d9',
                                },
                                {depracate=true,
                                 ifname='eth1',
                                 prefix='beef::/64'},
                             })
                  pm.ds:set_array{
                     {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary", ''},
                     {'ip -6 addr add beef::21c:42ff:fea7:f1d9/64 dev eth0', ''},

                                 }
                  mst.a(o:ready())
                  o:run()
                  pm.ds:check_used()
                  
                        end)
                        end)


describe("pm_v6_dhclient", function ()
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #v6_dhclient", function ()
                  pm = dpm.dpm:new{handlers={'v6_dhclient'}}
                  local o = pm.h.v6_dhclient
                  pm.skv:set(elsa_pa.OSPF_IFLIST_KEY, {"eth0"})
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
                  pm.skv:set(elsa_pa.OSPF_IFLIST_KEY, {})
                  o:run()

                  pm.ds:check_used()

                        end)
                           end)

describe("pm_dnsmasq", function ()
            local pm
            local conf = '/tmp/t-dnsmasq.conf'
            local dns_server_string = 'dhcp-option=option:dns-server,'
            local pm, o
            before_each(function ()
                           pm = dpm.dpm:new{handlers={'dnsmasq'},
                                            config={dnsmasq_conf_filename=conf},
                                           }
                           o = pm.h.dnsmasq
                           pm.skv:set(elsa_pa.OSPF_USP_KEY, {})
                           pm.skv:set(elsa_pa.OSPF_LAP_KEY, 
                                      {{ifname='eth0',
                                        prefix='dead::/64',
                                        owner=true},
                                       {ifname='eth0',
                                        prefix='beef::/64',
                                        owner=true,
                                        depracate=true},
                                       {ifname='eth0',
                                        prefix='10.1.42.0/24',
                                        address='10.1.42.1',
                                        owner=true},
                                      })
                        end)
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("works #dnsmasq", function ()
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
                  mst.a(not string.find(s, dns_server_string, nil, true), 'dns server should not be set') -- explicit v4/v6 DHCP server should not be used
                  mst.a(not string.find(s, 'port=0'), 'should not use hp dns')


                  -- 2nd run should do nothing, as state hasn't changed
                  o:run()

                  -- then, we change state => should get called with reload
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY,
                             {pm.skv:get(elsa_pa.OSPF_LAP_KEY)[1]})
                  o:run()

                  -- v4 address should be gone as we zapped it
                  local s = mst.read_filename_to_string(conf)
                  mst.a(not string.find(s, '10.1.42.6'), 'valid ipv4 address?')


                  -- get rid of state, make sure cleanup kills dnsmasq
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, {})
                  o:run()

                  pm.ds:check_used()
                        end)
            it("works in ospf mode too #dnsmasq_hp", function ()
                  o.config.use_hp_ospf = true
                  pm.ds:set_array{
                     {'/usr/share/hnet/dnsmasq_handler.sh start /tmp/t-dnsmasq.conf', ''},
                                 }
                  o:run()
                  local s = mst.read_filename_to_string(conf)
                  mst.a(string.find(s, 'port=0'), 'should use hp dns')
                  mst.a(string.find(s, dns_server_string, nil, true),
                        'dns server should be set', s, dns_server_string) 
                                         end)
                       end)

describe("pm_memory", function ()
            local pm
            after_each(function ()
                          pm:done()
                          local r = loop:clear()
                          mst.a(not r, 'left after', r)
                       end)
            it("does nothing ;) #memory", function ()
                  pm =  dpm.dpm:new{handlers={'memory'}}
                  local o = pm.h.memory
                  -- run twice, just for fun
                  o:run()
                  o:run()
                  -- tick twice, just for fun
                  o:tick()
                  o:tick()

                                  end)
                      end)

describe("pm_netifd", function ()
            it("works #netifd", function ()
                  local pm = dpm.dpm:new{handlers={'netifd_pull', 'netifd_push'}, config={test=true}}
                  local o1 = pm.h.netifd_pull
                  local o2 = pm.h.netifd_push
                  -- should be nop w/o state
                  o1:maybe_run()
                  o2:maybe_run()
                  --pm.skv:set(pm_netifd_pull.NETWORK_INTERFACE_UPDATED_KEY, 1)
                  pm.ds:set_array{
                     {'ubus call network.interface dump',
[[
{
	"interface": [
		{
			"interface": "lan1",
			"up": true,
			"proto": "hnet",
			"l3_device": "eth1",
			"device": "eth1",
		},
		{
			"interface": "lan2",
			"up": true,
			"proto": "hnet",
			"l3_device": "eth2",
			"device": "eth2",
		},
		{
			"interface": "lan0",
			"up": true,
			"proto": "hnet",
			"l3_device": "eth0",
			"device": "eth0",
		},
		{
			"interface": "ext",
			"up": true,
			"pending": false,
			"available": true,
			"autostart": true,
			"uptime": 307,
			"l3_device": "extdev",
			"proto": "dhcpv6",
			"device": "extdev",
			"metric": 0,
			"ipv6-address": [
				{
					"address": "2000:dead::c8d9:eaff:fe0b:e3ed",
					"mask": 64,
					"preferred": 14121,
					"valid": 86121
				},
				{
					"address": "fd2a:825a:7a8a:77ce:c8d9:eaff:fe0b:e3ed",
					"mask": 64,
					"preferred": 1518,
					"valid": 6918
				}
			],
			"ipv6-prefix": [
				{
					"address": "2000:dead:bee0::",
					"mask": 56,
					"preferred": 2692,
					"valid": 3692,
					"class": "h1_6",
					"assigned": {
						
					}
				},
				{
					"address": "2000:dead:bee1::",
					"mask": 56,
					"preferred": 2692,
					"valid": 3692,
					"class": "h1_6",
					"assigned": {
						
					}
				}
			],
			"dns-server": [
				"2000::2",
				"2001:100::1"
			],
			"dns-search": [
				"v6.lab.example.com"
			],
		}
	]
}
 ]]                    

                     },
                     {'ubus call network.interface notify_proto \'{action=0, interface="lan0", ["link-up"]=true, routes6={{gateway="dead::1", source="dead::/16", target="::/0"}}}\'', ''},
                     {'ubus call network.interface notify_proto \'{action=0, dns_search={"dummy"}, interface="lan1", ip6addr={{ipaddr="dead:beef::1", mask="32"}}, ipaddr={{ipaddr="10.2.2.2", mask="24"}}, ["link-up"]=true}\'', ''},
                     {'ubus call network.interface notify_proto \'{action=0, interface="lan2", ["link-up"]=true, routes={{gateway="10.1.1.1", source="10.0.0.0/8", target="0.0.0.0/0"}}}\'', ''},
                                 }

                  -- let's give it some state
                  local usps = {
                                -- IPv4 with route'
                                {prefix='10.0.0.0/8', 
                                 ifname='eth2',
                                 nh='10.1.1.1',
                                },

                                -- IPv6 without route'
                                {prefix='dead::/16',},
                                
                                -- IPv6 with route'
                                {prefix='dead::/16', 
                                 nh='dead::1', ifname='eth0'},
                                 
                             }
                  local laps = {
                     -- ipv4
                     {address='10.2.2.2',
                      prefix='10.2.2.0/24',
                      ifname='eth1'},

                     -- ipv6
                     {address='dead:beef::1',
                      prefix='dead:beef::/32',
                      ifname='eth1'},
                  }

                  pm.skv:set(elsa_pa.OSPF_USP_KEY, usps)
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, laps)
                  pm.skv:set(elsa_pa.HP_SEARCH_LIST_KEY, {'dummy'})
                  o1:maybe_run()
                  o2:maybe_run()
                  pm.ds:check_used()

                  -- make sure the set skv state matches what we have
                  mst.a(o1.set_pd_state:count() == 1)
                  for k, v in pairs(o1.set_pd_state)
                  do
                     mst_test.assert_repr_equal(pm.skv:get('pd.' .. k), v)
                  end
                  local exp = {
                     {pref=3926, prefix="2000:dead:bee0::/56", valid=4926}, 
                     {pref=3926, prefix="2000:dead:bee1::/56", valid=4926}}
                  mst_test.assert_repr_equal(pm.skv:get('pd.extdev'), exp)

                  -- another run shouldn't do anything
                  o1:run()
                  o2:run()

                  -- let's remove IPv6 stuff (arbitrary choice)
                  usps = {usps[1]}
                  laps = {laps[1]}

                  pm.skv:set(elsa_pa.OSPF_USP_KEY, usps)
                  pm.skv:set(elsa_pa.OSPF_LAP_KEY, laps)
                  pm.ds:set_array{
                     {'ubus call network.interface notify_proto \'{action=0, dns_search={"dummy"}, interface="lan1", ipaddr={{ipaddr="10.2.2.2", mask="24"}}, ["link-up"]=true}\'', ''},
                     {'ubus call network.interface notify_proto \'{action=0, interface="lan0", ["link-up"]=true}\'', ''},
                                 }
                  o2:run()
                  pm.ds:check_used()
                  pm:done()
                   end)

end)
