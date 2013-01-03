#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_core_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Dec 18 21:10:33 2012 mstenber
-- Last modified: Thu Jan  3 20:41:12 2013 mstenber
-- Edit time:     216 min
--

-- TO DO: 
-- - write many more tests
-- - cover the mdns.txt => draft-cheshire-dnsext-multicastdns MUST/SHOULDs
-- - queries: specific / ANY
-- - various MUST/SHOULDs in the draft

require "busted"
require "mdns_core"
require "mdns_ospf"
require "skv"
require "elsa_pa"
require "dnscodec"
require "dneigh"

local _dsm = require "dsm"

-- two different classes to play with
local _mdns = mdns_core.mdns
local _mdns_ospf = mdns_ospf.mdns

module("mdns_core_spec", package.seeall)

local MDNS_PORT = mdns_core.MDNS_PORT
local MDNS_MULTICAST_ADDRESS = mdns_core.MDNS_MULTICAST_ADDRESS

-- we store the received messages
dummynode = mst.create_class{class='dummynode'}

function dummynode:init()
   self.received = {}
end

function prettyprint_received_list(l)
   local t = {}
   for i, v in ipairs(l)
   do
      -- decoded message (human readable)
      local m = dnscodec.dns_message:decode(v[2])
      -- timestamp + that
      table.insert(t, {v[1], m})
   end
   return mst.repr(t)
end

function dummynode:repr_data()
   return string.format('rid=%s, #received=%d',
                        self.rid,
                        #self.received
                       )
   --prettyprint_received_list(self.received)
end

function dummynode:run()
   return
end

function dummynode:should_run()
   return false
end


function dummynode:next_time()
   return nil
end


function dummynode:recvfrom(...)
   table.insert(self.received, {self.time(), ...})
end

function create_node_callback(o)
   if o.dummy
   then
      return dummynode:new{rid=o.rid, time=o.time}
   end
   local n = _mdns_ospf:new{sendto=true,
                            rid=o.rid,
                            skv=o.skv,
                            time=o.time,
                           }
   function n.sendto(data, to, toport)
      mst.d('n.sendto', o.rid, data, to, toport)
      local l = mst.string_split(to, '%')
      mst.a(#l == 2, 'invalid address', to)
      local dst, ifname = unpack(l)
      o.sm.e:iterate_iid_neigh(o.rid, ifname, function (t)
                                  -- change the iid 
                                  -- (could use real address here too :p)
                                  local src = 'xxx%' .. t.iid
                                  local dn = o.sm.e.nodes[t.rid]
                                  mst.d('calling dn:recvfrom')
                                  dn:recvfrom(data, src, MDNS_PORT, to)
                                             end)
   end
   return n
end

local DUMMY_TTL=1234


-- fake mdns announcement
local an1 = {name={'Foo'}, rdata='Bar', rtype=42, ttl=DUMMY_TTL}
local msg1 = dnscodec.dns_message:encode{
   an={an1,
   },
                                        }
local msg1_ttl0 = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42},
   },
                                        }

local msg1_cf = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42, cache_flush=true, ttl=DUMMY_TTL},
   },
                                           }

local query1 = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=42}},
                                          }

local query1_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=42, qu=true}},
                                          }

local query1_kas = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=42, qu=true}},
   an={an1},
                                          }

function check_received_dummy_le(d, n)
   if #d.received > n
   then
      mst.a(false, ' too many # received', n, mst.repr(d))
   end
end

function check_received_dummy_eq(d, n, name)
   if #d.received ~= n
   then
      mst.a(false, 
            name .. ' wrong # received (exp,got)', n, #d.received,
            prettyprint_received_list(d.received))
   end
end

describe("mdns", function ()
            local n, dsm, mdns, dummy, s
            before_each(function ()
                           n = dneigh.dneigh:new{}
                           dsm = _dsm.dsm:new{e=n, port_offset=42536,
                                              create_callback=create_node_callback}
                           mdns = dsm:add_node{rid='n1'}
                           dummy = dsm:add_node{rid='dummy', dummy=true}
                           s = mdns.skv
                           s:set(elsa_pa.OSPF_LAP_KEY, {
                                    {ifname='eth0', owner=true},
                                    {ifname='eth1', owner=true},
                                                       })
                           n:connect_neigh(mdns.rid, 'eth1',
                                           dummy.rid, 'dummyif')
                        end)
            after_each(function ()
                          dsm:done()
                       end)

            function run_msg_states(msg, 
                                    expected_states, 
                                    expected_received_count)
                  mdns:run()
                  mdns:recvfrom(msg, 'dead:beef::1%eth0', MDNS_PORT)
                  local rr = mdns:get_if_own('eth1'):values()[1]
                  local dummies = 0
                  for k, v in pairs(expected_states)
                  do
                     if not v then dummies = dummies + 1 end
                  end
                  while (mst.table_count(expected_states) - dummies) > 0
                  do
                     mst.a(expected_states[rr.state])
                     expected_states[rr.state] = nil
                     local nt = mdns:next_time()
                     mst.a(nt)
                     dsm:set_time(nt)
                     mdns:run()
                  end
                  check_received_dummy_eq(dummy, expected_received_count, 'dummy')
                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()
            end
            it("works (CF=~unique)", function ()
                  expected_states = {[mdns_core.STATE_P1]=true,
                                     [mdns_core.STATE_P2]=true,
                                     [mdns_core.STATE_P3]=true,
                                     [mdns_core.STATE_PW]=true,
                                     [mdns_core.STATE_A1]=true,
                                     [mdns_core.STATE_A2]=true,
                  }
                  run_msg_states(msg1_cf, expected_states, 5)
                        end)
            it("works (!CF=~shared)", function ()
                  expected_states = {[mdns_core.STATE_P1]=false,
                                     [mdns_core.STATE_P2]=false,
                                     [mdns_core.STATE_P3]=false,
                                     [mdns_core.STATE_PW]=false,
                                     [mdns_core.STATE_A1]=true,
                                     [mdns_core.STATE_A2]=true,
                  }
                  run_msg_states(msg1, expected_states, 2)
                        end)
end)

describe("multi-mdns setup", function ()
            local n
            local dsm
            local mdns1, mdns2, mdns3
            local dummy1, dummy2, dummy3
            before_each(function ()
                  -- basic idea: 'a source' behind one mdns node two
                  -- other mdns nodes (connected in a triangle) and
                  -- 'dummy' nodes connected to each mdns interface of
                  -- interest

                  -- this is pathological case where everyone owns all
                  -- of their interfaces. it should still work, though..
                  n = dneigh.dneigh:new{}
                  dsm = _dsm.dsm:new{e=n, port_offset=42576,
                                     create_callback=create_node_callback}
                  mdns1 = dsm:add_node{rid='n1'}
                  mdns2 = dsm:add_node{rid='n2'}
                  mdns3 = dsm:add_node{rid='n3'}
                  dummy1 = dsm:add_node{rid='dummy1', dummy=true}
                  dummy2 = dsm:add_node{rid='dummy2', dummy=true}
                  dummy3 = dsm:add_node{rid='dummy3', dummy=true}
                  local s = mdns1.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='id1', owner=true},
                           {ifname='i123', owner=true},
                           {ifname='i12', owner=true},
                           {ifname='i13', owner=true},
                                              })

                  local s = mdns2.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='id2', owner=true},
                           {ifname='i213', owner=true},
                           {ifname='i21', owner=true},
                           {ifname='i23', owner=true},
                                              })

                  local s = mdns3.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='id3', owner=true},
                           {ifname='i312', owner=true}, 
                           {ifname='i31', owner=true}, 
                           {ifname='i32', owner=true}, 
                                              })

                  -- one shared segment
                  n:connect_neigh(mdns1.rid, 'i123',
                                  mdns2.rid, 'i213',
                                  mdns3.rid, 'i312')

                  -- point-to-point connections
                  n:connect_neigh(mdns1.rid, 'i12',
                                  mdns2.rid, 'i21')

                  n:connect_neigh(mdns1.rid, 'i13', 
                                  mdns3.rid, 'i31')

                  n:connect_neigh(mdns2.rid, 'i23', 
                                  mdns3.rid, 'i32')

                  -- interface to each dummy node
                  n:connect_neigh(mdns1.rid, 'id1',
                                  dummy1.rid, 'dummyif')
                  n:connect_neigh(mdns2.rid, 'id2',
                                  dummy2.rid, 'dummyif')
                  n:connect_neigh(mdns3.rid, 'id3',
                                  dummy3.rid, 'dummyif')
                        end)
            after_each(function ()
                          dsm:done()
                       end)
            function check_received_dummies_eq(n1, n2, n3)
               check_received_dummy_eq(dummy3, n3)
               check_received_dummy_eq(dummy2, n2)
               check_received_dummy_eq(dummy1, n1)
            end
            function clear_received()
               dummy1.received = {}
               dummy2.received = {}
               dummy3.received = {}
            end
            function check_dummy_received_counts(dummy1_count, 
                                                 dummy2_count,
                                                 dummy3_count)

               local c1 = #dummy1.received
               local c2 = #dummy2.received
               local c3 = #dummy3.received
               mst.d('dummy count', c1, c2, c3)
               check_received_dummy_le(dummy3, c3)
               check_received_dummy_le(dummy2, c2)
               check_received_dummy_le(dummy1, c1)
               return c3 == dummy3_count and 
                  c2 == dummy2_count and 
                  c1 == dummy1_count
            end
            it("works #multi", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_cf, 'dead:beef::1%id1', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  check_received_dummies_eq(0, 5, 5)

                  -- make sure that if we run long enough, system
                  -- state gets emptied
                  local r = dsm:run_nodes_and_advance_time(DUMMY_TTL * 2)
                  mst.a(r, 'propagation did not terminate')
                  check_received_dummies_eq(0, 5, 5)

                  for i, mdns in ipairs{mdns1, mdns2, mdns3}
                  do
                     mst.a(mdns:own_count() == 0, mdns.if2own)
                     mst.a(mdns:cache_count() == 0, mdns.if2cache)
                  end

                   end)
            it("won't propagate 0 ttl stuff", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_ttl0, 'dead:beef::1%id1', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  check_received_dummies_eq(0, 0, 0)
                   end)
            it("shared records - 2x announce, 1x ttl=0 #shb", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1, 'dead:beef::1%id1', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- two announcements, final ttl=0
                  -- (1 shouldn't, as it's same interface)
                  check_received_dummies_eq(0, 3, 3)
                   end)
            function wait_dummy_received_counts(dummy1_count,
                                                dummy2_count,
                                                dummy3_count)
               
               function dummies_desired()
                  return check_dummy_received_counts(dummy1_count,
                                                     dummy2_count,
                                                     dummy3_count)
               end
               if dummies_desired() then return end
               local r = dsm:run_nodes_and_advance_time(123, {until_callback=dummies_desired})
               mst.a(r, 'propagation did not terminate')
               mst.a(dummies_desired(), 'dummies not in desired state')
            end
            function check_dummy_received_to(dummy, tostring)
               local r = dummy.received
               local i = #r
               mst.a(i > 0)
               mst.a(string.sub(r[i][5], 1, #tostring) == tostring,
                     'to address mismatch', r[i])
            end
            it("query works #q", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')
                  mdns1:recvfrom(msg1, 'dead:beef::1%id1', MDNS_PORT)

                  wait_dummy_received_counts(0, 1, 1)
                  local elapsed = dsm.t-dsm.start_t
                  mst.d('propagation done in', elapsed)
                  -- typically ~0.3 second?
                  mst.a(elapsed < 0.5, 'took too long', elapsed, #dummy1.received, #dummy2.received, #dummy3.received)

                  -- then, wait for the second announce
                  clear_received()
                  wait_dummy_received_counts(0, 1, 1)
                  local elapsed = dsm.t-dsm.start_t
                  mst.d('propagation done in', elapsed)
                  -- typically ~1.3 second?
                  mst.a(elapsed < 1.5, 'took too long', elapsed, #dummy1.received, #dummy2.received, #dummy3.received)

                  -- couple of different cases

                  -- a) unicast should work always (even when stuff
                  -- has just been multicast)
                  -- dummy2 asks => dummy2 gets (3 times)
                  -- s5.20 SHOULD
                  mst.d('a) 2x unicast query')
                  clear_received()
                  mdns2:recvfrom(query1, 'blarg%id2', MDNS_PORT + 1)
                  mdns2:recvfrom(query1, 'blarg%id2', MDNS_PORT + 1)
                  wait_dummy_received_counts(0, 2, 0)
                  -- make sure it is unicast
                  check_dummy_received_to(dummy2, 'blarg')
                  clear_received()

                  -- s5.18 SHOULD
                  mst.d('a1) qu')
                  mdns2:recvfrom(query1_qu, 'blarg%id2', MDNS_PORT)
                  wait_dummy_received_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  check_dummy_received_to(dummy2, 'blarg')

                  -- b) multicast should NOT work right after
                  -- multicast was received (0.2 to account for
                  -- processing delay)
                  mst.d('b) no-direct-multicast-reply')
                  clear_received()
                  mdns2:recvfrom(query1, 'blarg%id2', MDNS_PORT)
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  wait_dummy_received_counts(0, 0, 0)

                  -- c) multicast should work 'a bit' after
                  mst.d('c) advancing time')
                  clear_received()
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1, 'blarg%id2', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  mst.a(check_dummy_received_counts(0, 0, 0))
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 1, 0))
                  clear_received()

                  -- move time forward bit
                  dsm:advance_time(0.7)

                  -- yet another query should not provide result
                  -- within 0,8sec (1sec spam limit)
                  mdns2:recvfrom(query1, 'blarg%id2', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 0, 0))

                  -- d) KAS should work
                  -- => no answer if known
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1_kas, 'blarg%id2', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  mst.a(check_dummy_received_counts(0, 0, 0))
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 0, 0))

                  -- e) should reply with multicast to qu
                  -- if enough time has elapsed
                  -- s5.19 SHOULD
                  dsm:advance_time(DUMMY_TTL / 2)
                  mdns2:recvfrom(query1_qu, 'blarg%id2', MDNS_PORT)
                  wait_dummy_received_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  check_dummy_received_to(dummy2, MDNS_MULTICAST_ADDRESS)
                  

                   end)
end)
