#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_core_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Oct  4 23:56:40 2012 mstenber
-- Last modified: Fri Nov 30 11:10:48 2012 mstenber
-- Edit time:     229 min
--

-- testsuite for the pm_core
-- with inputs/outputs precalculated and checked to be ~sane

require 'busted'
require 'elsa_pa'
require 'pm_core'
require 'skv'
require 'ospfcodec'
require 'pa'

module("pm_core_spec", package.seeall)

local TEMP_RADVD_CONF='/tmp/t-radvd.conf'
local TEMP_DHCPD_CONF='/tmp/t-dhcpd.conf'
local TEMP_DHCPD6_CONF='/tmp/t-dhcpd6.conf'
local TEMP_DNSMASQ_CONF='/tmp/t-dnsmasq.conf'

local _delsa = require 'delsa'
delsa = _delsa.delsa

require 'dshell'

local usp_dead_tlv = ospfcodec.usp_ac_tlv:encode{prefix='dead::/16'}

assert(mst.create_hash_type == 'md5', 
       'we support only md5 based tests -' .. 
          ' code might or might not work with sha1 fallback')

-- bits and pieces == fragments for each sub-handler
-- (out of which we create the combined ones)

local bird_start = {
   {'/usr/share/hnet/bird4_handler.sh start 135.214.18.0', ''},
}

local bird_stop = {
   {'/usr/share/hnet/bird4_handler.sh stop', ''},
}

local dhcp4_start = {
   {'/usr/share/hnet/dhcpd_handler.sh 4 1 /var/run/pm-pid-dhcpd /tmp/t-dhcpd.conf', ''},
}

local dhcp4_stop = {
   {'/usr/share/hnet/dhcpd_handler.sh 4 0 /var/run/pm-pid-dhcpd /tmp/t-dhcpd.conf', ''},

}

local dhcp6_start = {
   {'/usr/share/hnet/dhcpd_handler.sh 6 1 /var/run/pm-pid-dhcpd6 /tmp/t-dhcpd6.conf', ''},
}

local dhcp6_stop = {
   {'/usr/share/hnet/dhcpd_handler.sh 6 0 /var/run/pm-pid-dhcpd6 /tmp/t-dhcpd6.conf', ''},
}

local dnsmasq_start = {
   {'/usr/share/hnet/dnsmasq_handler.sh start /tmp/t-dnsmasq.conf', ''},
}

local dnsmasq_stop = {
   {'/usr/share/hnet/dnsmasq_handler.sh stop', ''},
}


local radvd_stop = mst.array:new{
   {'killall -9 radvd', ''},
   {'rm -f /var/run/radvd.pid', ''},
}

local radvd_start = {
   {'radvd -C /tmp/t-radvd.conf', ''},
}

local radvd_restart = mst.table_copy(radvd_stop)
mst.array_extend(radvd_restart, radvd_start)


local v4_addr_check = {
   {'ip -4 addr', 
    [[
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue state UNKNOWN 
    inet 127.0.0.1/8 scope host lo
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    inet 10.211.55.3/24 brd 10.211.55.255 scope global eth2
428: nk_tap_mstenber: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 500
    inet 192.168.42.1/24 brd 192.168.42.255 scope global nk_tap_mstenber
     ]]}
}

local v4_addr_set = {
   {'ifconfig eth2 10.171.21.15 netmask 255.255.255.0', ''},
}

local v4_dhclient_wrong_start = {
   {'ls -1 /var/run', [[
pm-pid-dhclient-eth1
                       ]]},
   {'/usr/share/hnet/dhclient_handler.sh stop eth1 /var/run/pm-pid-dhclient-eth1', ''},
   {'/usr/share/hnet/dhclient_handler.sh start eth0 /var/run/pm-pid-dhclient-eth0', ''},
}

local v4_dhclient_stop = {
   {'ls -1 /var/run', [[
pm-pid-dhclient-eth0
                       ]]},
   {'/usr/share/hnet/dhclient_handler.sh stop eth0 /var/run/pm-pid-dhclient-eth0', ''},
}

local v6_dhclient_start = {
   {'ls -1 /var/run', ''},
   {'/usr/share/hnet/dhclient6_handler.sh start eth2 /var/run/pm-pid-dhclient6-eth2', ''},
}

local v6_dhclient_stop = {
   {'ls -1 /var/run', [[
pm-pid-dhclient6-eth2
                       ]]},
   -- we leave them running for now -> ignore
   --{'/usr/share/hnet/dhclient6_handler.sh stop eth2 /var/run/pm-pid-dhclient6-eth2', ''},
}

local v6_listen_ra_start = {
   {'/usr/share/hnet/listen_ra_handler.sh start eth0', ''},
}

local v6_route_start = {
   {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
    [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]]},
   {'ip -6 addr del dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 dev eth2', ''},
   {'ifconfig eth2 | grep HWaddr',
    'eth2      Link encap:Ethernet  HWaddr 00:1c:42:a7:f1:d9  '},
   {'ip -6 addr add dead:fa5:c92f:74db:21c:42ff:fea7:f1d9/64 dev eth2', ''},
}

local v6_route_stop = {
   {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
    [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]]},
   {'ip -6 addr del dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 dev eth2', ''},
}


local v6_rule_start = {
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                          0:	from all to beef::/16 lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   -- add the rule back + relevant route
   {'ip -6 route flush table 1000', ''},
   {'ip -6 route add default via fe80:1234:2345:3456:4567:5678:6789:789a dev eth0 table 1000', ''},
   -- main table default
   {'ip -6 route add default via fe80:1234:2345:3456:4567:5678:6789:789a dev eth0 metric 123456', ''},
   -- add the local routing rule
   {'ip -6 rule add from all to dead::/16 table main pref 1000', ''},
}

local v6_rule_flush_no_nh = {
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   -- delete old rule, even if it matches (almost - not same nh info)
   {'ip -6 rule del from dead::/16 table 1000 pref 1112', ''},
}

local v6_rule_stop_nh_juggled = {
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                          0:	from all to beef::/16 lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   {'ip -6 rule del from dead::/16 table 1000 pref 1112', ''},
   --{'ip -6 route del default via fe80:1234:2345:3456:4567:5678:6789:789a dev eth0 metric 123456', ''},
   --taken care of in nh juggling?
   {'ip -6 route del default via 1.2.3.4 dev eth0 metric 123456', ''},
}

-- miscellaneous odds and ends

nh_juggling = {{'ip -6 route', [[
default via 1.2.3.4 dev eth0
                                                        ]]},
               {'ip -6 rule', [[
0:	from all lookup local 
0:	from all to beef::/16 lookup local 
1000:	from all to dead::/16 lookup main
1112:	from dead::/16 lookup 1000 
16383:	from all lookup main 
]]},
               {'ip -6 route del default via fe80:1234:2345:3456:4567:5678:6789:789a dev eth0 metric 123456', ''},
               {'ip -6 route flush table 1000'},
               {'ip -6 route add default via 1.2.3.4 dev eth0 table 1000'},
               {'ip -6 route add default via 1.2.3.4 dev eth0 metric 123456'},
               {'ip -6 route', [[
default via 1.2.3.4 dev eth0
                                                        ]]}

}

describe("pm", function ()
            local s, e, ep, pm, ds

            before_each(function ()
                           local myrid = 'myrid'
                           local myrid = 1234567
                           local orid = 12345678
                           ds = dshell.dshell:new{}
                           s = skv.skv:new{long_lived=true, port=42424}
                           e = delsa:new{iid={[myrid]={{index=42, name='eth2'}}},
                                         lsas={[orid]=usp_dead_tlv},
                                         hwf={[myrid]='foo'},
                                         assume_connected=true,
                                        }

                           ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid=myrid}
                           e:add_router(ep)
                           s:set(elsa_pa.OSPF_RID_KEY, myrid)
                           s:set(elsa_pa.PD_IFLIST_KEY, {'eth0', 'eth1'})
                           s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.PREFIX_KEY .. 'eth0', 
                                 -- prefix[,valid]
                                 'dead::/16'
                                )
                           s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.DNS_KEY .. 'eth0', 
                                 -- dns
                                 'dead::1'
                                )
                           s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.DNS_SEARCH_KEY .. 'eth0', 
                                 -- dns search
                                 'dummy.local'
                                )
                           s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.NH_KEY .. 'eth0', 
                                 -- just address
                                 'fe80:1234:2345:3456:4567:5678:6789:789a'
                                )

                           pm = pm_core.pm:new{skv=s, shell=ds:get_shell(),
                                               radvd_conf_filename=TEMP_RADVD_CONF,
                                               dhcpd_conf_filename=TEMP_DHCPD_CONF,
                                               dhcpd6_conf_filename=TEMP_DHCPD6_CONF,
                                              }
                        end)
            after_each(function ()
                          pm:done()
                          ep:done()
                          e:done()
                          s:done()
                       end)
            it("works #w", function ()
                  local d = mst.array:new{}

                  d:extend(unpack{
                              --bird_start, -- n/a, no v4?
                              -- no v4 dhcpd either
                              dhcp4_stop,

                              dhcp6_start,
                              v4_addr_check,
                              -- no v4 addr
                              --v4_addr_set,
                              v4_dhclient_wrong_start,
                              v6_dhclient_start,
                              v6_route_start,
                              v6_rule_start,
                              radvd_restart,
                                 }
                          )

                  ds:set_array(d)
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())
                  ds:check_used()
                  local s = mst.read_filename_to_string(TEMP_RADVD_CONF)
                  mst.a(string.find(s, 'RDNSS'), 'RDNSS missing')
                  mst.a(string.find(s, 'DNSSL'), 'DNSSL missing')
                  local s = mst.read_filename_to_string(TEMP_DHCPD6_CONF)
                  mst.a(string.find(s, 'subnet6'), 'subnet6 missing')

                        end)
            it("works w/ dnsmasq #wd", function ()
                  local d = mst.array:new{}
                  -- get rid of old pm
                  pm:done()

                  -- create new one, with dnsmasq enabled
                  pm = pm_core.pm:new{skv=s, shell=ds:get_shell(),
                                      dnsmasq_conf_filename=TEMP_DNSMASQ_CONF,
                                      use_dnsmasq=true,
                                     }

                  d:extend(unpack{
                              --bird_start, -- n/a, no v4?
                              v4_addr_check,
                              -- no v4 addr
                              --v4_addr_set,
                              v4_dhclient_wrong_start,
                              v6_dhclient_start,
                              v6_route_start,
                              v6_rule_start,
                              dnsmasq_start,
                                 }
                          )

                  ds:set_array(d)
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())
                  ds:check_used()
                  local s = mst.read_filename_to_string(TEMP_DNSMASQ_CONF)
                  mst.a(string.find(s, 'server'), 'server missing')
                  mst.a(string.find(s, 'range'), 'dhcp-range missing')
                        end)
            it("works - but no nh => table should be empty", function ()
                  local d = mst.array:new{}

                  -- get rid of the nh
                  s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.NH_KEY .. 'eth0', nil)

                  d:extend(unpack{
                              --bird_start, -- n/a, no v4?
                              -- no v4 dhcpd either
                              dhcp4_stop,

                              dhcp6_start,
                              v4_addr_check,
                              -- no v4 addr
                              --v4_addr_set,
                              v4_dhclient_wrong_start,
                              v6_dhclient_start,
                              v6_listen_ra_start,
                              v6_route_start,
                              v6_rule_flush_no_nh, 
                              radvd_restart,
                                 }
                          )

                  ds:set_array(d)
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())
                  ds:check_used()
                  
                                                             end)
            it("works - post-ULA period => v4 should occur #v4", function ()
                  local d = mst.array:new{}

                  d:extend(unpack{bird_start,
                                  dhcp4_start,
                                  dhcp6_start,
                                  v4_addr_check,
                                  v4_addr_set,
                                  v4_dhclient_wrong_start,
                                  v6_dhclient_start,
                                  v6_route_start,
                                  v6_rule_start,
                                  radvd_restart,
                                 }
                          )

                  -- tick
                  -- => find that NH has changed
                  -- => should rewrite that
                  d:extend(nh_juggling)

                  -- second run =~ nop

                  -- then cleanup
                  d:extend(unpack{
                              bird_stop,
                              dhcp4_stop,
                              dhcp6_stop,
                              v4_addr_check,
                              v4_dhclient_stop,
                              v6_dhclient_stop,
                              v6_route_stop,
                              v6_rule_stop_nh_juggled,
                              radvd_stop,
                                 })
                  -- XXX
                  ds:set_array(d)

                  local pa = ep.pa
                  -- change other rid so we have highest one -> v4!
                  local lowrid = 123
                  e.lsas={[lowrid]=usp_dead_tlv}
                  pa.disable_always_ula = true
                  pa.new_prefix_assignment = 10
                  pa.start_time = pa.start_time - pa.new_prefix_assignment - 10
                  ep:ospf_changed()
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())

                  -- make sure tick is harmless too
                  -- (it should result in next hop being checked)
                  mst.a(not pm.nh['eth0'])
                  pm:tick()
                  pm:tick()
                  mst.a(pm.nh['eth0'])

                  local d = mst.read_filename_to_string(TEMP_RADVD_CONF)
                  local ipv4_match = '10[.]%d+[.]%d+[.]%d+'

                  mst.a(not string.find(d, ipv4_match), 'IPv4 address?!?')


                  local d = mst.read_filename_to_string(TEMP_DHCPD_CONF)
                  mst.a(string.find(d, ipv4_match), 'no IPv4 address?!?')


                  -- make sure that explicitly clearing the SKV
                  -- results in correct results - that is, commands to
                  -- clear all IF state
                  s:clear()
                  mst.a(pm:run())
                  mst.a(not pm:run())

                  ds:check_used()
                  
                   end)

               end)

