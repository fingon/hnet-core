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
-- Last modified: Wed Dec 19 17:13:06 2012 mstenber
-- Edit time:     83 min
--

require "busted"
require "mdns_core"
require "skv"
require "elsa_pa"
require "dnscodec"
require "dneigh"
local _dsm = require "dsm"

module("mdns_core_spec", package.seeall)

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


function dummynode:recvmsg(src, data)
   table.insert(self.received, {src, data})
end

function create_node_callback(o)
   if o.dummy
   then
      return dummynode:new{rid=o.rid}
   end
   local n = mdns_core.mdns:new{sendmsg=true,
                                rid=o.rid,
                                skv=o.skv,
                                time=o.time,
                               }
   function n.sendmsg(to, data)
      mst.d('n.sendmsg', to, data)
      local l = mst.string_split(to, '%')
      mst.a(#l == 2, 'invalid address', to)
      local dst, ifname = unpack(l)
      o.sm.e:iterate_iid_neigh(o.rid, ifname, function (t)
                                  -- change the iid 
                                  -- (could use real address here too :p)
                                  local src = 'xxx%' .. t.iid
                                  local dn = o.sm.e.nodes[t.rid]
                                  mst.d('calling dn:recvmsg')
                                  dn:recvmsg(src, data)
                                             end)
   end
   return n
end


-- fake mdns announcement
local msg1 = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42},
   },
                                        }

local msg1_cf = dnscodec.dns_message:encode{
   an={{name={'Foo'}, rdata='Bar', rtype=42, cache_flush=true},
   },
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
                  mdns:recvmsg('dead:beef::1%eth0', msg)
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

                  mdns1:recvmsg('dead:beef::1%eth0', msg1_cf)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  mst.a(#dummy3.received == 5, 'wrong # sent?', dummy3)
                  mst.a(#dummy2.received == 5, 'wrong # sent?', dummy2)
                  mst.a(#dummy1.received == 5, 'wrong # sent?', dummy1)

                   end)

end)
