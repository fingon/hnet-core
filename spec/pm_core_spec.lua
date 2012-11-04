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
-- Last modified: Sun Nov  4 00:48:11 2012 mstenber
-- Edit time:     111 min
--

-- testsuite for the pm_core
-- with inputs/outputs precalculated and checked to be ~sane

require 'busted'
require 'elsa_pa'
require 'pm_core'
require 'skv'
require 'codec'
require 'pa'

module("pm_core_spec", package.seeall)

local TEMP_RADVD_CONF='/tmp/radvd.conf'
local TEMP_DHCPD_CONF='/tmp/dhcpd.conf'
local TEMP_DHCPD6_CONF='/tmp/dhcpd6.conf'

local _delsa = require 'delsa'
delsa = _delsa.delsa

require 'dshell'

local usp_dead_tlv = codec.usp_ac_tlv:encode{prefix='dead::/16'}

local x = 
   pa.create_hash_type == 'md5' and
   {'ip -6 addr add dead:fa5:c92f:74db:21c:42ff:fea7:f1d9/64 dev eth2', ''} -- md5
   or
   {'ip -6 addr add dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 dev eth2', ''} -- sha1
-- XXX - probably broken after alg change

local v6_dhcpd=
   {
   {'killall -9 radvd', ''},
   {'rm -f /var/run/radvd.pid', ''},
   {'radvd -C /tmp/radvd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 4 0 /var/run/pm-pid-dhcpd /tmp/dhcpd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 6 1 /var/run/pm-pid-dhcpd6 /tmp/dhcpd6.conf', ''},
   }

local v46_dhcpd=
   {
   {'killall -9 radvd', ''},
   {'rm -f /var/run/radvd.pid', ''},
   {'radvd -C /tmp/radvd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 4 1 /var/run/pm-pid-dhcpd /tmp/dhcpd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 6 1 /var/run/pm-pid-dhcpd6 /tmp/dhcpd6.conf', ''},
   }

local no_dhcpd=
   {
   {'killall -9 radvd', ''},
   {'rm -f /var/run/radvd.pid', ''},
--   {'radvd -C /tmp/radvd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 4 0 /var/run/pm-pid-dhcpd /tmp/dhcpd.conf', ''},
   {'/usr/share/hnet/dhcpd_handler.sh 6 0 /var/run/pm-pid-dhcpd6 /tmp/dhcpd6.conf', ''},
   }



local lap_base = {                     
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
   x,
   {'ls -1 /var/run', [[
pm-pid-dhclient-eth1
                       ]]},
   {'/usr/share/hnet/dhclient_handler.sh stop eth1 /var/run/pm-pid-dhclient-eth1', ''},
   {'/usr/share/hnet/dhclient_handler.sh start eth0 /var/run/pm-pid-dhclient-eth0', ''},
}

local lap_end = {
   {'ip -4 addr', 
    [[
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue state UNKNOWN 
    inet 127.0.0.1/8 scope host lo
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    inet 10.211.55.3/24 brd 10.211.55.255 scope global eth2
428: nk_tap_mstenber: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 500
    inet 192.168.42.1/24 brd 192.168.42.255 scope global nk_tap_mstenber
     ]]},
}

local rule_base = {
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                          0:	from all to beef::/16 lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   -- delete old rule, even if it matches (almost - not same nh info)
   {'ip -6 rule del from dead::/16 table 1000 pref 1112', ''},
   -- add the rule back + relevant route
   {'ip -6 rule add from dead::/16 table 1000 pref 1112', ''},
   {'ip -6 route flush table 1000', ''},
   {'ip -6 route add default via fe80:1234:2345:3456:4567:5678:6789:789a dev eth0 table 1000', ''},
   
   -- add the local routing rule
   {'ip -6 rule add from all to dead::/16 table main pref 1000', ''},
}

local rule_no_nh = {
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   -- delete old rule, even if it matches (almost - not same nh info)
   {'ip -6 rule del from dead::/16 table 1000 pref 1112', ''},
}

cleanup = {
   {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
    [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]]},
   {'ip -6 addr del dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 dev eth2', ''},
   {'ls -1 /var/run', [[
pm-pid-dhclient-eth0
                       ]]},
   {'/usr/share/hnet/dhclient_handler.sh stop eth0 /var/run/pm-pid-dhclient-eth0', ''},
   {'ip -6 rule',
    [[
                          0:	from all lookup local 
                          0:	from all to beef::/16 lookup local 
                             1112:	from dead::/16 lookup 1000 
                          16383:	from all lookup main 
                       ]]},
   {'ip -6 rule del from dead::/16 table 1000 pref 1112', ''},

}

describe("pm", function ()
            local s, e, ep, pm, ds

            before_each(function ()
                           ds = dshell.dshell:new{}
                           s = skv.skv:new{long_lived=true, port=42424}
                           e = delsa:new{iid={myrid={{index=42, name='eth2'}}},
                                         lsas={rid1=usp_dead_tlv},
                                         hwf={myrid='foo'},
                                         assume_connected=true,
                                        }
                           ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid='myrid'}

                           s:set(elsa_pa.OSPF_RID_KEY, 'myrid')
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
                  local d = mst.table_copy(lap_base)
                  mst.array_extend(d, rule_base)
                  mst.array_extend(d, lap_end)
                  mst.array_extend(d, v6_dhcpd)
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
            it("works - but no nh => table should be empty", function ()
                  -- get rid of the nh
                  s:set(elsa_pa.PD_SKVPREFIX .. elsa_pa.NH_KEY .. 'eth0', nil)
                  local d = mst.table_copy(lap_base)
                  mst.array_extend(d, rule_no_nh)
                  mst.array_extend(d, lap_end)
                  mst.array_extend(d, v6_dhcpd)
                  ds:set_array(d)
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())
                  ds:check_used()
                  
                                                             end)
            it("works - post-ULA period => v4 should occur #v4", function ()
                  local d = mst.table_copy(lap_base)
                  mst.array_extend(d, rule_base)
                  mst.array_extend(d, lap_end)
                  mst.array_extend(d, {{'ifconfig eth2 10.171.21.41 netmask 255.255.255.0', ''}})
                  mst.array_extend(d, v46_dhcpd)
                  -- second run
                  mst.array_extend(d, cleanup)
                  mst.array_extend(d, lap_end)
                  mst.array_extend(d, no_dhcpd)

                  ds:set_array(d)

                  local pa = ep.pa
                  -- change other rid so we have highest one -> v4!
                  e.lsas={arid1=usp_dead_tlv}
                  pa.disable_always_ula = true
                  pa.new_prefix_assignment = 10
                  pa.start_time = pa.start_time - pa.new_prefix_assignment - 10
                  ep:run()
                  mst.a(pm:run())
                  mst.a(not pm:run())

                  local d = mst.read_filename_to_string(TEMP_RADVD_CONF)
                  mst.a(not string.find(d, '10.'), 'IPv4 address?!?')


                  local d = mst.read_filename_to_string(TEMP_DHCPD_CONF)
                  mst.a(string.find(d, '10.'), 'no IPv4 address?!?')


                  -- make sure that explicitly clearing the SKV
                  -- results in correct results - that is, commands to
                  -- clear all IF state
                  s:clear()
                  mst.a(pm:run())
                  mst.a(not pm:run())

                  ds:check_used()
                  
                   end)

               end)

