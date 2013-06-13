#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_client_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May  9 14:45:24 2013 mstenber
-- Last modified: Thu Jun 13 12:56:06 2013 mstenber
-- Edit time:     67 min
--

require 'busted'
require 'mdns_client'
require 'dns_const'
require 'dshell'
require 'mst_test'

module('mdns_client_spec', package.seeall)

-- 4 different cases to test

-- a) CF in cache when we start => return that

-- b) CF shows up in cache later => return that immediately

-- c) non-CF shows up in cache at some point => return that at timeout

-- d) timeout

local q = {name={'foo', 'com'},
           qclass=dns_const.CLASS_IN,
           qtype=dns_const.TYPE_A}

local rr = {name={'foo', 'com'},
            rtype=dns_const.TYPE_A,
            rclass=dns_const.CLASS_IN,
            rdata_a='2.3.4.5'}

local rr_cf = {name={'foo', 'com'},
               rtype=dns_const.TYPE_A,
               rclass=dns_const.CLASS_IN,
               rdata_a='1.2.3.4',
               cache_flush=true}

local ifname = 'dummy'             

local ip4_addr_get = {
   'ip -4 addr', 
   [[
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 qdisc noqueue state UNKNOWN 
    inet 127.0.0.1/8 scope host lo
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
    inet 10.211.55.3/24 brd 10.211.55.255 scope global eth2
428: nk_tap_mstenber: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 500
    inet 192.168.42.1/24 brd 192.168.42.255 scope global nk_tap_mstenber
]]
}

local ip6_addr_get = {
   "ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
    [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]],
}

local N_IF=4 -- dummy + 3 in ip4_addr_get

local N_IPV4=3
local N_IPV6=2
local N_IP=N_IPV4+N_IPV6

describe("mdns_client", function ()
            local c
            local t
            local t_start = 123
            local ifo
            before_each(function ()
                           t = t_start
                           ds = dshell.dshell:new{}
                           c = mdns_client.mdns_client:new{sendto=function (...)
                                                                  end,
                                                           time=function ()
                                                              return t
                                                           end,
                                                           shell=ds:get_shell()}
                           ifo = c:get_if(ifname)
                        end)
            after_each(function ()
                          c:done()
                          -- no assert, as not _always_ doing this
                          scr.clear_scr()
                       end)
            it("works with prepopulated CF entry [=>sync] #a", function ()
                  ifo.cache:insert_rr(rr_cf)
                  local r, got_cf = c:resolve_ifname_q(ifname, q, 0.1)
                  mst.a(mst.repr_equal(r, {rr_cf}), 'not same')
                  mst.a(got_cf)
                   end)
            it("works with CF that shows up later #b", function ()
                  local got1, got1_cf
                  local got2, got2_cf
                  local cnt = 0
                  mst_test.inject_snitch(mdns_client.mdns_client_request,
                                         'init',
                                         function ()
                                            cnt = cnt + 1
                                         end)
                  scr.run(function ()
                             scr.sleep(0.01)
                             mst.d('inserting cf entry')
                             ifo.cache:insert_rr(rr_cf)
                             scr.sleep(0.1)
                             mst.d('inserting non-cf entry')
                             ifo.cache:insert_rr(rr)
                          end)
                  scr.run(function ()
                             got1, got1_cf = c:resolve_ifname_q(ifname, q, 1)
                          end)
                  scr.run(function ()
                             got2, got2_cf = c:resolve_ifname_q(ifname, q, 1)
                          end)
                  local r = ssloop.loop():loop_until(function ()
                                                        return got1 and got2
                                                     end, 1)
                  mst.a(r, 'timed out')
                  mst_test.assert_repr_equal(got1, {rr_cf})
                  mst.a(got1_cf)
                  mst_test.assert_repr_equal(got1_cf, got2_cf)
                  mst_test.assert_repr_equal(got1, got2)
                  mst_test.assert_repr_equal(cnt, 1)
                   end)
            it("works with non-CF #c", function ()
                  local got, got_cf
                  scr.run(function ()
                             scr.sleep(0.01)
                             mst.d('inserting cf entry')
                             ifo.cache:insert_rr(rr)
                          end)
                  scr.run(function ()
                             got, got_cf = c:resolve_ifname_q(ifname, q, 0.1)
                          end)
                  local r = ssloop.loop():loop_until(function () return got end, 1)
                  mst.a(r, 'timed out')
                  mst.a(mst.repr_equal(got, {rr}), 'not same', got, {rr})
                  mst.a(not got_cf)

                   end)
            it("timeout #d", function ()
                  local r = scr.timeouted_run_async_call(1, 
                                                         c.resolve_ifname_q,
                                                         c,
                                                         ifname, 
                                                         q,
                                                        0.1)
                  mst.a(not r, 'no timeout(?)')
                        end)
            it("can populate it's own entries if called for #own", function ()
                  -- by default, dummy if should be there
                  mst_test.assert_repr_equal(mst.table_count(c.ifname2if), 1,
                                             'initial')
                  c:update_own_records(nil)
                  mst_test.assert_repr_equal(mst.table_count(c.ifname2if), 1,
                                             'after nil update')

                  -- now we should actually do something for real
                  ds:set_array{ip4_addr_get,
                               ip6_addr_get}
                  c:update_own_records('foo')
                  -- add eth2, lo, 6rd
                  mst_test.assert_repr_equal(mst.table_count(c.ifname2if), N_IF,
                                            'after foo')
                  local cnt = c:get_if('eth2').own:count()
                  mst_test.assert_repr_equal(cnt, N_IP * 2)

                  -- second foo, should be nop
                  c:update_own_records('foo')
                  mst_test.assert_repr_equal(mst.table_count(c.ifname2if), N_IF,
                                            'after foo')
                  local cnt = c:get_if('eth2').own:count()
                  mst_test.assert_repr_equal(cnt, N_IP * 2)

                  -- now change name to bar
                  c:update_own_records('bar')
                  mst_test.assert_repr_equal(mst.table_count(c.ifname2if), N_IF,
                                            'after bar')
                  local cnt = c:get_if('eth2').own:count()
                  -- initially the cache-flush set reverse records
                  -- (PTRs) get replaced immediately. A/AAAA will hang
                  -- around until they get expired (very soon)
                  mst_test.assert_repr_equal(cnt, N_IP * 3)

                  -- however, the old ones should expire 'after awhile'
                  -- (but nsec records get added in; we have 1 name + N_IP addresses => we should have N_IP * 2 + (1 + N_IP) in the end)
                  
                  local ifo = c:get_if('eth2')
                  while true
                  do
                     local cnt = ifo.own:count()
                     mst.d('time', t, 'cnt', cnt)
                     if cnt == N_IP * 2 + (1 + N_IP)
                     then
                        break
                     end
                     t = t + 0.1
                     if t > t_start + 10
                     then
                        local ol = ifo.own:values()
                        mst.a(false, 'timeout',  
                              ifo.own:count(), ol)
                        
                     end
                     c:run()
                  end

                  ds:check_used()
                   end)
            it("can generate list of local binary prefixes", function ()
                  ds:set_array{ip6_addr_get}
                  local m = c:get_local_binary_prefix_set()
                  mst.a(m, 'get_local_binary_prefix_set failed')
                  local m = c:get_local_binary_prefix_set()
                  mst.a(m, 'get_local_binary_prefix_set failed')
                  ds:check_used()

                   end)
                   end)
