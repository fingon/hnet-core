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
-- Last modified: Wed Dec 19 16:36:47 2012 mstenber
-- Edit time:     60 min
--

require "busted"
require "mdns_core"
require "skv"
require "elsa_pa"
require "dnscodec"
require "dneigh"
require "dsm"

module("mdns_core_spec", package.seeall)

-- we store the received messages
dummynode = mst.create_class{class='dummynode'}

function dummynode:init()
   self.received = {}
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
   an={{name={'foo'}, rdata='bar', rtype=42, cache_flush=true},
   },
                                        }

describe("mdns", function ()
            it("works", function ()
                  local s = skv.skv:new{long_lived=true, port=42535}
                  local mdns = mdns_core.mdns:new{sendmsg=true,
                                                  skv=s}
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth2', owner=true},
                           {ifname='eth1'},
                                              })
                  mdns:run()
                  mdns:recvmsg('dead:beef::1%eth0', msg1)

                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()
                  mdns:done()
                  s:done()
                   end)
            it("state machine works too #dsm", function ()
                  local n = dneigh.dneigh:new{}
                  local dsm = dsm.dsm:new{e=n, port_offset=42536,
                                          create_callback=create_node_callback}
                  local mdns = dsm:add_node{rid='n1'}
                  local dummy = dsm:add_node{rid='dummy', dummy=true}
                  local s = mdns.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth1', owner=true},
                                              })
                  n:connect_neigh(mdns.rid, 'eth1',
                                  dummy.rid, 'dummyif')
                  expected_states = {[mdns_core.STATE_P1]=true,
                                     [mdns_core.STATE_P2]=true,
                                     [mdns_core.STATE_P3]=true,
                                     [mdns_core.STATE_PW]=true,
                                     [mdns_core.STATE_A1]=true,
                                     [mdns_core.STATE_A2]=true,
                  }
                  
                  mdns:run()
                  mdns:recvmsg('dead:beef::1%eth0', msg1)
                  local rr = mdns:get_if_own('eth1'):values()[1]
                  while mst.table_count(expected_states) > 0
                  do
                     expected_states[rr.state] = nil
                     local nt = mdns:next_time()
                     mst.a(nt)
                     dsm:set_time(nt)
                     mdns:run()
                  end
                  mst.a(#dummy.received == 5, 'wrong # sent?', dummy)

                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()


                  dsm:done()
                   end)
end)

