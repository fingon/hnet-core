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
-- Last modified: Fri Dec 21 13:27:03 2012 mstenber
-- Edit time:     141 min
--

-- TO DO: 
-- - write many more tests
-- - cover the mdns.txt => draft-cheshire-dnsext-multicastdns MUST/SHOULDs
-- - queries: specific / ANY
-- - various MUST/SHOULDs in the draft

require "busted"
require "mdns_core"
require "skv"
require "elsa_pa"
require "dnscodec"
require "dneigh"
local _dsm = require "dsm"

module("mdns_core_spec", package.seeall)

local MDNS_PORT = mdns_core.MDNS_PORT

-- we store the received messages
dummynode = mst.create_class{class='dummynode'}

function dummynode:init()
   self.received = {}
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
   table.insert(self.received, {...})
end

function create_node_callback(o)
   if o.dummy
   then
      return dummynode:new{rid=o.rid}
   end
   local n = mdns_core.mdns:new{sendto=true,
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
                                  dn:recvfrom(data, src, MDNS_PORT)
                                             end)
   end
   return n
end


-- fake mdns announcement
local an1 = {name={'Foo'}, rdata='Bar', rtype=42, ttl=1234}
local msg1 = dnscodec.dns_message:encode{
   an={an1,
   },
                                        }
local msg1_ttl0 = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42},
   },
                                        }

local msg1_cf = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42, cache_flush=true, ttl=1234},
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
                                    expected_states, expected_received_count)
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
                  mst.a(#dummy.received == expected_received_count, 
                        'wrong # sent?', dummy)
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
                           {ifname='eth0', owner=true},
                           {ifname='eth1', owner=true},
                           {ifname='eth3', owner=true},
                                              })

                  local s = mdns2.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth1', owner=true},
                           {ifname='eth3', owner=true},
                                              })

                  local s = mdns3.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth1', owner=true},
                           {ifname='eth2', owner=true},
                                              })

                  -- eth0 = private
                  -- one shared segment (eth1)
                  n:connect_neigh(mdns1.rid, 'eth1',
                                  mdns2.rid, 'eth1',
                                  mdns3.rid, 'eth1')

                  -- eth2/3 = connections to other' nodes (direct)
                  n:connect_neigh(mdns1.rid, 'eth2',
                                  mdns2.rid, 'eth2')
                  n:connect_neigh(mdns1.rid, 'eth3',
                                  mdns3.rid, 'eth2')
                  n:connect_neigh(mdns2.rid, 'eth3',
                                  mdns3.rid, 'eth3')

                  -- and then dummy interfaces to each node
                  n:connect_neigh(mdns1.rid, 'eth0',
                                  dummy1.rid, 'dummyif')
                  n:connect_neigh(mdns2.rid, 'eth0',
                                  dummy2.rid, 'dummyif')
                  n:connect_neigh(mdns3.rid, 'eth0',
                                  dummy3.rid, 'dummyif')
                        end)
            after_each(function ()
                          dsm:done()
                       end)
            it("works #multi", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_cf, 'dead:beef::1%eth0', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  mst.a(#dummy3.received == 5, 'wrong # sent?', dummy3)
                  mst.a(#dummy2.received == 5, 'wrong # sent?', dummy2)
                  mst.a(#dummy1.received == 0, 'wrong # sent?', dummy1)

                   end)
            it("won't propagate 0 ttl stuff", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_ttl0, 'dead:beef::1%eth0', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  mst.a(#dummy3.received == 0, 'wrong # sent?', dummy3)
                  mst.a(#dummy2.received == 0, 'wrong # sent?', dummy2)
                  mst.a(#dummy1.received == 0, 'wrong # sent?', dummy1)
                   end)
            it("shared records - 2x announce, 1x ttl=0", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1, 'dead:beef::1%eth0', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- two announcements, final ttl=0
                  -- (1 shouldn't, as it's same interface)
                  mst.a(#dummy3.received == 3, 'wrong # sent?', #dummy3.received, dummy3)
                  mst.a(#dummy2.received == 3, 'wrong # sent?', #dummy2.received, dummy2)
                  mst.a(#dummy1.received == 0, 'wrong # sent?', #dummy1.received, dummy1)
                   end)
            function check_dummy_received_counts(dummy1_count, dummy2_count,
                                                 dummy3_count)

               local c1 = #dummy1.received
               local c2 = #dummy2.received
               local c3 = #dummy3.received
               mst.d('dummy count', c1, c2, c3)
               mst.a(c3 <= dummy3_count, 
                     'too many dummy3 messages', 
                     c3, dummy3_count)
               mst.a(c2 <= dummy2_count, 
                     'too many dummy2 messages', 
                     c2, dummy2_count)
               mst.a(c1 <= dummy1_count, 
                     'too many dummy1 messages', 
                     c1, dummy1_count)
               return c3 == dummy3_count and 
                  c2 == dummy2_count and 
                  c1 == dummy1_count
            end
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
            end
            it("query works #q", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')
                  mdns1:recvfrom(msg1, 'dead:beef::1%eth0', MDNS_PORT)

                  wait_dummy_received_counts(0, 1, 1)
                  local elapsed = dsm.t-dsm.start_t
                  mst.d('propagation done in', elapsed)
                  -- typically ~0.3 second?
                  mst.a(elapsed < 0.5, 'took too long', elapsed, #dummy1.received, #dummy2.received, #dummy3.received)

                  -- then, wait for the second announce
                  wait_dummy_received_counts(0, 2, 2)
                  local elapsed = dsm.t-dsm.start_t
                  mst.d('propagation done in', elapsed)
                  -- typically ~1.3 second?
                  mst.a(elapsed < 1.5, 'took too long', elapsed, #dummy1.received, #dummy2.received, #dummy3.received)

                  -- couple of different cases

                  -- a) unicast should work always (even when stuff
                  -- has just been multicast)
                  -- dummy2 asks => dummy2 gets (3 times)
                  mdns2:recvfrom(query1, 'blarg%eth0', 12345)
                  mdns2:recvfrom(query1, 'blarg%eth0', 12345)
                  wait_dummy_received_counts(0, 4, 2)
                  mdns2:recvfrom(query1_qu, 'blarg%eth0', MDNS_PORT)
                  wait_dummy_received_counts(0, 5, 2)

                  -- b) multicast should NOT work right after
                  -- multicast was received (0.2 to account for
                  -- processing delay)
                  mdns2:recvfrom(query1, 'blarg%eth0', MDNS_PORT)
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  wait_dummy_received_counts(0, 5, 2)

                  -- c) multicast should work 'a bit' after
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1, 'blarg%eth0', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  mst.a(check_dummy_received_counts(0, 5, 2))
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 6, 2))

                  -- move time forward bit
                  dsm:advance_time(0.7)

                  -- yet another query should not provide result
                  -- within 0,8sec (1sec spam limit)
                  mdns2:recvfrom(query1, 'blarg%eth0', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 6, 2))

                  -- d) KAS should work
                  -- => no answer if known
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1_kas, 'blarg%eth0', MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  mst.a(check_dummy_received_counts(0, 6, 2))
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  mst.a(check_dummy_received_counts(0, 6, 2))


                   end)
end)
