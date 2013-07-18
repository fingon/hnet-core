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
-- Last modified: Thu Jul 18 15:40:54 2013 mstenber
-- Edit time:     119 min
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
            rdata_a='2.3.4.5',
            valid=12345,
}

local rr_cf = {name={'foo', 'com'},
               rtype=dns_const.TYPE_A,
               rclass=dns_const.CLASS_IN,
               rdata_a='1.2.3.4',
               cache_flush=true,
               valid=12345,
}

local ifname = 'dummy'             

local N_IF=1 + 2 -- dummy + 2 in ip4_addr_get

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

local N_IPV4=2 -- 2 globals (we should ignore loopback)

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

local N_IPV6=2 -- 6rd one should not show up

local N_IP=N_IPV4+N_IPV6

local ip4_addr_get2 = {
   'ip -4 addr', 
   [[
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 1000
       inet 10.211.55.4/24 brd 10.211.55.255 scope global eth2
428: nk_tap_mstenber: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP qlen 500
       inet 192.168.42.1/24 brd 192.168.42.255 scope global nk_tap_mstenber
    ]]
}

local ip6_addr_get2 = {
   "ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
   [[2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
     inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1da/64 scope global dynamic 
     inet6 dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic
    ]],
}


local N2_IPV4=2
local N2_IPV6=2
local N2_IP=N2_IPV4+N2_IPV6

local observers = 0
mst_test.inject_snitch(mst_eventful.event, 'add_observer',
function ()
observers = observers + 1
end)

mst_test.inject_snitch(mst_eventful.event, 'remove_observer',
function ()
observers = observers - 1
end)

describe("mdns_client", function ()
            local c
            local t
            local t_start = 123
            local ifo
            before_each(function ()
                           observers = 0
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
                          -- at termination, should have no observers
                          mst.a(#ifo.cache.inserted.observers == 0, ifo.cache.observers)

                          c:done()
                          -- no assert, as not _always_ doing this
                          scr.clear_scr()
                          mst.a(observers == 0, 'observers left', observers)
                       end)
            it("works with prepopulated CF entry [=>sync] #a", function ()
                  ifo.cache:insert_rr(rr_cf)
                  local r, got_cf = c:resolve_ifname_q(ifname, q, 0.1)
                  mst.a(r and #r == 1, 'not 1 result', r)
                  mst.a(dns_db.rr.equals(r[1], rr_cf), 
                        'not rr-equal', r[1], rr_cf)
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
                  mst.a(#got1 == 1)
                  mst.a(dns_db.rr.equals(got1[1], rr_cf), 
                        'not rr-equal', got1[1], rr_cf)
                  mst.a(got1_cf)
                  mst.a(#got2 == 1)
                  mst.a(dns_db.rr.equals(got2[1], rr_cf), 
                        'not rr-equal', got2[1], rr_cf)
                  mst_test.assert_repr_equal(got1_cf, got2_cf)
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
                  mst.a(#got == 1)
                  mst.a(dns_db.rr.equals(got[1], rr), 
                        'not rr-equal', got[1], rr)
                  mst.a(not got_cf)

                                       end)
            it("timeout #d", function ()
                  local r = scr.timeouted_run_async_call(1, 
                                                         c.resolve_ifname_q,
                                                         c,
                                                         ifname, 
                                                         q,
                                                         0.1)
                  mst.a(r and #r == 0, 'should return empty list even if timeout', r)
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
                  local nif = mst.table_count(c.ifname2if)
                  --mst.a(nif and N_IF)
                  --mst.d(nif, N_IF, mst.table_keys(c.ifname2if))
                  mst_test.assert_repr_equal(nif, N_IF, '#if after foo')

                  local ifo = c:get_if('eth2')
                  function run_until_ifo_count(n)
                     while true
                     do
                        local cnt = ifo.own:count()
                        mst.d('time', t, 'cnt', cnt)
                        if cnt == n
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

                  end

                  local cnt = ifo.own:count()
                  mst_test.assert_repr_equal(cnt, N_IP * 2,
                                             'after first foo (cnt)')

                  -- second foo, should be nop
                  c:update_own_records('foo')
                  local nif = mst.table_count(c.ifname2if)
                  mst_test.assert_repr_equal(nif, N_IF, '#if after foo')
                  local cnt = ifo.own:count()
                  mst_test.assert_repr_equal(cnt, N_IP * 2, 'cnt after foo')

                  -- now change name to bar
                  c:update_own_records('bar')

                  -- however, the old ones should expire 'after awhile'
                  -- (but nsec records get added in; we have 1 name + N_IP addresses => we should have N_IP * 2 + (1 + N_IP) in the end)
                  run_until_ifo_count(N_IP * 2 + (1 + N_IP))

                  ds:check_used()

                  -- now, some wild stuff - change addresses _and_ name!
                  ds:set_array{ip4_addr_get2, ip6_addr_get2}

                  t = t + mdns_core.IF_INFO_VALIDITY_PERIOD + 10
                  t_start = t
                  c:update_own_records('baz')
                  ds:check_used()

                  run_until_ifo_count(N2_IP * 2 + (1 + N2_IP))

                                                                   end)
            it("can get own records from lap too #lap", function ()
                  c:update_own_records_from_ospf_lap('foo', 
                                       {
                                          {address='1.2.3.4'},
                                          {address='dead:beef::1'},
                                       })
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
