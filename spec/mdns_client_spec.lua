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
-- Last modified: Wed May 29 22:08:49 2013 mstenber
-- Edit time:     31 min
--

require 'busted'
require 'mdns_client'
require 'dns_const'
require 'dshell'

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

local ip_addr_get = {
   {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
    [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]]},
}


describe("mdns_client", function ()
            local c
            local ifo
            before_each(function ()
                           ds = dshell.dshell:new{}
                           c = mdns_client.mdns_client:new{sendto=function (...)
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
                  local got, got_cf
                  scr.run(function ()
                             scr.sleep(0.01)
                             mst.d('inserting cf entry')
                             ifo.cache:insert_rr(rr_cf)
                             scr.sleep(0.1)
                             mst.d('inserting non-cf entry')
                             ifo.cache:insert_rr(rr)
                          end)
                  scr.run(function ()
                             got, got_cf = c:resolve_ifname_q(ifname, q, 1)
                          end)
                  local r = ssloop.loop():loop_until(function ()
                                                        return got
                                                     end, 1)
                  mst.a(r, 'timed out')
                  mst.a(mst.repr_equal(got, {rr_cf}), 'not same', got, {rr_cf})
                  mst.a(got_cf)
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
                  local r = ssloop.loop():loop_until(function ()
                                                        return got
                                                     end, 1)
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
                  ds:set_array(ip_addr_get)
                  c:update_own_records(nil)
                  c:update_own_records('foo')
                  -- XXX - check somehow it works well
                  ds:check_used()
                   end)
            it("can generate list of local binary prefixes", function ()
                  ds:set_array(ip_addr_get)
                  local m = c:get_local_binary_prefix_set()
                  mst.a(m, 'get_local_binary_prefix_set failed')
                  local m = c:get_local_binary_prefix_set()
                  mst.a(m, 'get_local_binary_prefix_set failed')
                  ds:check_used()

                   end)
                   end)
