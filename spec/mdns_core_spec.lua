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
-- Last modified: Mon Jan  7 12:57:00 2013 mstenber
-- Edit time:     282 min
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

-- class mydsm is variant of dsm, which keeps track of all installed dummies
-- and provides mdns-specific assertions regarding those dummies
mydsm = _dsm.dsm:new_subclass{class='mydsm'}

function mydsm:init()
   self.dummies = {}
   _dsm.dsm.init(self)
end

function mydsm:assert_receiveds_eq(...)
   local l = {...}
   mst.a(#l == #self.dummies, 'mismatch on #dummies <> #receiveds')
   for i, v in ipairs(l)
   do
      self.dummies[i]:assert_received_eq(v)
   end
end

function mydsm:clear_receiveds()
   for i, d in ipairs(self.dummies)
   do
      d.received = {}
   end
end

function mydsm:check_queries_done()
   for i, n in ipairs(self:get_nodes())
   do
      local q = n.queries
      if q and #q>0 then return false end
   end
   return true
end

function mydsm:assert_queries_done()
   self:a(self:check_queries_done(), 'still queries left')
end

function mydsm:wait_queries_done()
   if self:check_queries_done() then return end
   local r = 
      self:run_nodes_and_advance_time(123, 
                                      {until_callback=
                                       function ()
                                          return self:check_queries_done()
                                       end})
   self:a(r, 'propagation did not terminate')
   self:a(check_queries_done(), 'queries still not done')
end


function mydsm:wait_receiveds_counts(...)
   local l = {...}
   mst.a(#l == #self.dummies, 'mismatch on #dummies <> #receiveds')
   function dummies_desired()
      local ok = true
      for i, v in ipairs(l)
      do
         local d = self.dummies[i]
         local c = #d.received
         d:assert_received_le(c)
         if c ~= v then ok=false end
      end
      return ok
   end
   if dummies_desired() then return end
   local r = self:run_nodes_and_advance_time(123, 
                                             {until_callback=dummies_desired})
   self:a(r, 'propagation did not terminate')
   self:a(dummies_desired(), 'dummies not in desired state')
end

-- class for storing results
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

function dummynode:assert_received_to(tostring)
   local r = self.received
   local i = #r
   self:a(i > 0)
   self:a(string.sub(r[i][5], 1, #tostring) == tostring,
          'to address mismatch', r[i])
end

function dummynode:assert_received_le(n)
   self:a(#self.received <= n, 'too many received')
end

function dummynode:assert_received_eq(n)
   self:a(#self.received == n,
          ' wrong # received (exp,got)', n, #self.received)
end

-- then utility callback for instantiating dummynodes/other nodes

function create_node_callback(o)
   if o.dummy
   then
      local d = dummynode:new{rid=o.rid, time=o.time}
      mst.a(o.dsm, 'dsm has to be set for dummy nodes')
      table.insert(o.dsm.dummies, d)
      return d
   end
   local cl = o.class or _mdns_ospf
   local n = cl:new{sendto=true,
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
local DUMMY_TYPE=42
local DUMMY_TYPE2=123

-- fake mdns announcement
local rr1 = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, ttl=DUMMY_TTL}

local rr1_cf = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, cache_flush=true, ttl=DUMMY_TTL}

local rr1_ttl0 = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, ttl=0}

local msg1 = dnscodec.dns_message:encode{an={rr1}}

local msg1_ttl0 = dnscodec.dns_message:encode{an={rr1_ttl0}}

local msg1_cf = dnscodec.dns_message:encode{an={rr1_cf}}

local query1 = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE}},
                                          }

local query1_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qu=true}},
                                          }

local query1_type_any_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=dnscodec.TYPE_ANY, qu=true}},
                                                 }

local query1_class_any_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qclass=dnscodec.CLASS_ANY, qu=true}},
                                                       }

local query1_type_nomatch_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=(DUMMY_TYPE+1), qu=true}},
                                                          }

local query1_class_nomatch_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qclass=(dnscodec.CLASS_IN+1), qu=true}},
                                                          }

local query1_kas = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qu=true}},
   an={rr1},
                                          }

describe("mdns", function ()
            local n, dsm, mdns, dummy, s
            before_each(function ()
                           n = dneigh.dneigh:new{}
                           dsm = mydsm:new{e=n, 
                                           port_offset=42536,
                                           create_callback=create_node_callback}
                           mdns = dsm:add_node{rid='n1', class=_mdns}
                           dummy = dsm:add_node{rid='dummy', 
                                                dsm=dsm, 
                                                dummy=true}
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

            function run_rr_states(orr, 
                                    expected_states, 
                                    expected_received_count)
                  mdns:run()
                  mdns:insert_if_own_rr('eth1', orr)
                  --mdns:recvfrom(msg, 'dead:beef::1%eth0', MDNS_PORT)
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
                  dummy:assert_received_eq(expected_received_count)
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
                  run_rr_states(rr1_cf, expected_states, 5)
                        end)
            it("works (!CF=~shared)", function ()
                  expected_states = {[mdns_core.STATE_P1]=false,
                                     [mdns_core.STATE_P2]=false,
                                     [mdns_core.STATE_P3]=false,
                                     [mdns_core.STATE_PW]=false,
                                     [mdns_core.STATE_A1]=true,
                                     [mdns_core.STATE_A2]=true,
                  }
                  run_rr_states(rr1, expected_states, 2)
                        end)
end)

describe("multi-mdns setup (mdns_ospf)", function ()
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
                  dsm = mydsm:new{e=n, port_offset=42576,
                                  create_callback=create_node_callback}
                  mdns1 = dsm:add_node{rid='n1'}
                  mdns2 = dsm:add_node{rid='n2'}
                  mdns3 = dsm:add_node{rid='n3'}
                  dummy1 = dsm:add_node{rid='dummy1', dsm=dsm, dummy=true}
                  dummy2 = dsm:add_node{rid='dummy2', dsm=dsm, dummy=true}
                  dummy3 = dsm:add_node{rid='dummy3', dsm=dsm, dummy=true}
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
                          -- wait awhile
                          -- make sure state empties eventually clearly
                          local r = dsm:run_nodes_and_advance_time(DUMMY_TTL * 2)
                          mst.a(r, 'propagation did not terminate')

                          -- ensure that state is really empty
                          for i, mdns in ipairs{mdns1, mdns2, mdns3}
                          do
                             mst.a(mdns:own_count() == 0, mdns.if2own)
                             mst.a(mdns:cache_count() == 0, mdns.if2cache)
                          end

                          dsm:done()
                       end)
            it("works #multi", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_cf, 'dead:beef::1%id1', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  dsm:assert_receiveds_eq(0, 5, 5)

                   end)
            it("won't propagate 0 ttl stuff", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_ttl0, 'dead:beef::1%id1', MDNS_PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  dsm:assert_receiveds_eq(0, 0, 0)
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
                  dsm:assert_receiveds_eq(0, 3, 3)
                   end)
            it("query works #q", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')
                  mdns1:recvfrom(msg1, 'dead:beef::1%id1', MDNS_PORT)

                  dsm:wait_receiveds_counts(0, 1, 1)
                  local elapsed = dsm.t-dsm.start_t
                  mst.d('propagation done in', elapsed)
                  -- typically ~0.3 second?
                  mst.a(elapsed < 0.5, 'took too long', elapsed, #dummy1.received, #dummy2.received, #dummy3.received)

                  -- then, wait for the second announce
                  dsm:clear_receiveds()
                  dsm:wait_receiveds_counts(0, 1, 1)
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
                  dsm:clear_receiveds()
                  local DUMMY_IP='blarg'
                  local DUMMY_IF='id2'
                  local DUMMY_SRC=DUMMY_IP .. '%' .. DUMMY_IF

                  mdns2:recvfrom(query1, DUMMY_SRC, MDNS_PORT + 1)
                  mdns2:recvfrom(query1, DUMMY_SRC, MDNS_PORT + 1)
                  dsm:wait_receiveds_counts(0, 2, 0)
                  -- make sure it is unicast
                  dummy2:assert_received_to(DUMMY_IP)
                  dsm:clear_receiveds()

                  -- s5.18 SHOULD
                  mst.d('a1) qu')
                  mdns2:recvfrom(query1_qu, DUMMY_SRC, MDNS_PORT)
                  dsm:wait_receiveds_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  dummy2:assert_received_to(DUMMY_IP)

                  -- b) multicast should NOT work right after
                  -- multicast was received (0.2 to account for
                  -- processing delay)
                  mst.d('b) no-direct-multicast-reply')
                  dsm:clear_receiveds()
                  mdns2:recvfrom(query1, DUMMY_SRC, MDNS_PORT)
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:wait_receiveds_counts(0, 0, 0)

                  -- c) multicast should work 'a bit' after
                  mst.d('c) advancing time')
                  dsm:clear_receiveds()
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1, DUMMY_SRC, MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  dsm:assert_receiveds_eq(0, 0, 0)
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 1, 0)
                  dsm:clear_receiveds()

                  -- move time forward bit
                  dsm:advance_time(0.7)

                  -- yet another query should not provide result
                  -- within 0,8sec (1sec spam limit)
                  mdns2:recvfrom(query1, DUMMY_SRC, MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 0, 0)

                  -- d) KAS should work
                  -- => no answer if known
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1_kas, DUMMY_SRC, MDNS_PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  dsm:assert_receiveds_eq(0, 0, 0)
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 0, 0)

                  -- e) check that different queries work
                  -- as expected; that is, type=all results something,
                  -- but no type => no answer
                  -- s6.2
                  mdns2:recvfrom(query1_type_any_qu, DUMMY_SRC, MDNS_PORT)
                  mdns2:recvfrom(query1_class_any_qu, DUMMY_SRC, MDNS_PORT)
                  mdns2:recvfrom(query1_class_any_qu, DUMMY_SRC, MDNS_PORT)
                  mdns2:recvfrom(query1_type_nomatch_qu, DUMMY_SRC, MDNS_PORT)
                  mdns2:recvfrom(query1_class_nomatch_qu, DUMMY_SRC, MDNS_PORT)

                  -- shouldn't have caused any query to be waiting..
                  dsm:assert_queries_done()
                  -- Just one reply (qtype=any); qtype=nonexistent
                  -- => no answer
                  dsm:assert_receiveds_eq(0, 3, 0)
                  dsm:clear_receiveds()

                  -- .. last ..) should reply with multicast to qu
                  -- if enough time has elapsed
                  -- s5.19 SHOULD
                  dsm:advance_time(DUMMY_TTL / 2)
                  mdns2:recvfrom(query1_qu, DUMMY_SRC, MDNS_PORT)
                  dsm:wait_receiveds_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  dummy2:assert_received_to(MDNS_MULTICAST_ADDRESS)
                   end)
end)
