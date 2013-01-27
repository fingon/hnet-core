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
-- Last modified: Sun Jan 27 10:33:31 2013 mstenber
-- Edit time:     645 min
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

-- dospf is dummy ospf skv-state simulator; what it does is whatever
-- normal OSPF would, in terms of skv functionality, for mdns; takes
-- local mdns, and provides ospf-mdns back (non-local cache state)

dospf = mst.create_class{class='dospf', mandatory={'dsm'}}

function dospf:register_to_skvs()
   local dsm = self.dsm
   self.f = function (k, v) self:kv_changed(k, v) end
   for i, n in ipairs(dsm:get_nodes())
   do
      local s = n.skv
      if s
      then
         s:add_change_observer(self.f)
      end
   end
end

function dospf:kv_changed(k, v)
   -- if own skv key changes, it's dirty
   if k == elsa_pa.MDNS_OWN_SKV_KEY
   then
      self.dirty = true
   end
end

function dospf:should_run()
   -- do we have updated state to propagate between skv's?
   return self.dirty
end

function dospf:next_time()
   return nil
end

function dospf:run()
   if not self.dirty then return end
   self.dirty = nil
   -- what dirty means is that we have to create custom view for each
   -- node, s.t. it does NOT contain cache entries they publish, but
   -- entries from all other nodes. sigh. this is O(n^2), but not
   -- really a problem as such, as this is just test code.
   for i, n in ipairs(self.dsm:get_nodes())
   do
      if n.skv
      then
         local rest = {}
         for j, n2 in ipairs(self.dsm:get_nodes())
         do
            if i ~= j and n2.skv
            then
               mst.array_extend(rest, n2.skv:get(elsa_pa.MDNS_OWN_SKV_KEY) or {})
            end
         end
         n.skv:set(elsa_pa.MDNS_OSPF_SKV_KEY, rest)
      end
   end
end

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
         d:assert_received_le(v)
         --mst.d('#receiveds in', i, c, v)
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
   local l = {...}
   -- decode the payload
   local b = l[1]
   local o, err = dnscodec.dns_message:decode(b)
   self:a(o, 'unable decode', mst.string_to_hex(b), err)
   l[1] = o
   table.insert(self.received, {self.time(), unpack(l)})
end

function dummynode:assert_received_to(tostring)
   local r = self.received
   local i = #r
   self:a(i > 0)
   self:a(string.sub(r[i][5], 1, #tostring) == tostring,
          'to address mismatch', tostring, r[i])
end

function dummynode:assert_received_le(n)
   self:a(#self.received <= n, 'too many received')
end

function dummynode:assert_received_eq(n)
   self:a(#self.received == n,
          ' wrong # received (exp,got)', n, #self.received)
end

function dummynode:get_last_e(ofs)
   ofs = ofs or 0
   local i = #self.received - ofs
   self:a(i >= 1)
   local o = self.received[i]
   self:a(o, 'received[] == nil?!?')
   return o
end

function dummynode:get_last_msg(ofs)
   local e = self:get_last_e(ofs)
   local msg = e[2]
   self:a(msg, 'nil msg?!?', e)
   return msg
end

function dummynode:sanity_check_last_multicast_response()
   local msg = self:get_last_msg()

   self:sanity_check_last_multicast()

   -- s18.4 MUST
   self:a(msg.h.id == 0, 'non-zero id', msg)

   self:sanity_check_last_response()

   -- s18.13 MUST
   self:a(msg.h.tc == false, 'TC must not be set in multicast responses')
end

function dummynode:sanity_check_last_unicast_response(qid)
   local msg = self:get_last_msg()

   self:assert_received_to(self.rid)

   -- (legacy unicast)
   -- s6.47/48 MUST have id == resp id
   
   -- (unicast?)
   -- s18.5 MUST q id == resp id
   qid = qid or 0
   mst.a(msg.h.id == qid, 'wrong id', qid, msg)

   self:sanity_check_last_response()
end

function dummynode:sanity_check_last_legacy_unicast_response(qid)
   -- s6.49 MUST NOT set cache flush bit in unicast (legacy) responses
   -- s10.8 cache-flush MUST NOT be set in non-5353
   local msg = self:get_last_msg()
   for i, rr in ipairs(msg.an or {})
   do
      self:a(not rr.cache_flush, 'cache flush set in legacy unicast response')
   end
   for i, rr in ipairs(msg.ns or {})
   do
      self:a(not rr.cache_flush, 'cache flush set in legacy unicast response')
   end

   self:sanity_check_last_unicast_response(qid)
   
end

function dummynode:sanity_check_last_probe()
   local msg = self:get_last_msg()
   self:sanity_check_last_multicast_query()

   -- S8.2 SHOULD
   mst.a(#msg.qd > 0)
   mst.a(msg.qd[1].qtype == dns_const.TYPE_ANY, 'non-ANY probe')
   
   -- s8.6 SHOULD
   mst.a(msg.qd[1].qu == true, 'non-qu probe')
end

function dummynode:sanity_check_last_announce()
   self:sanity_check_last_multicast_response()
end

function dummynode:sanity_check_last_multicast_query()
   local msg = self:get_last_msg()

   self:sanity_check_last_multicast()

   -- s18.3 SHOULD 
   self:a(msg.h.id == 0, 'non-zero id', msg)

   -- s18.8 MUST
   mst.a(msg.h.opcode == 0, 'non-zero opcode', msg)

   self:sanity_check_last_query()
end

function dummynode:sanity_check_last_multicast()
   local msg = self:get_last_msg()
   local e = self:get_last_e()

   -- s6.16/17 MUST be mdns_const.MULTICAST_ADDRESS
   -- s6.16/17 MUST be mdns_const.PORT
   self:assert_received_to(mdns_const.MULTICAST_ADDRESS)
   self:a(e[4] == mdns_const.PORT)

   -- s18.15/16 MUST (reception not checked)
   self:a(msg.h.rd == false, 'RD set in multicast', msg)

   -- s18.17/18 MUST (reception not checked)
   self:a(msg.h.ra == false, 'RA set in multicast', msg)

   -- s18.19/20 MUST (reception not checked)
   -- XXX - draft doesn't say _multicast_
   self:a(msg.h.z == 0, 'Z set in multicast', msg)

   -- s18.21/22 MUST (reception not checked)
   self:a(msg.h.ad == false, 'AD set in multicast', msg)

   -- s18.23/24 MUST (reception not checked)
   self:a(msg.h.cd == false, 'CD set in multicast', msg)

   -- s18.25/26 MUST
   self:a(msg.h.rcode == 0, 'rcode set in multicast', msg)
end

function dummynode:sanity_check_last_query()
   local msg = self:get_last_msg()

   -- s18.6/7 MUST
   self:a(not msg.h.qr, 'QR must not be set in query', msg)
   -- s18.9/10 MUST
   self:a(msg.h.aa == false, 'AA must not be set in queries')
   -- s10.9 cache-flush bit MUST NOT be set in KAS
   for i, rr in ipairs(msg.an)
   do
      mst.a(not rr.cache_flush, 'cache flush set in query answers')
   end
end

function dummynode:sanity_check_last_response()
   local msg = self:get_last_msg()

   -- s18.6/7 MUST
   self:a(msg.h.qr, 'QR must be set in response', msg)

   -- s6.7 MUST
   mst.a(#msg.qd == 0)

   -- s18.11 MUST
   -- (we only handle multicast domains)
   self:a(msg.h.aa == true, 'AA must be set in responses')

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
                                  local src = n.rid .. '%' .. t.iid
                                  local dn = o.sm.e.nodes[t.rid]
                                  mst.d('calling dn:recvfrom', t.iid)
                                  dn:recvfrom(data, src, mdns_const.PORT, to)
                                             end)
   end
   return n
end

local DUMMY_TTL=1234
local DUMMY_TYPE=42
local DUMMY_TYPE2=123
local CLASS_IN=dns_const.CLASS_IN
local DUMMY_ID1=7
local DUMMY_ID2=1234
local DUMMY_ID3=1235

-- fake mdns announcement material
local rr1 = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, ttl=DUMMY_TTL}

local rr1_cf = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, rclass=CLASS_IN, cache_flush=true, ttl=DUMMY_TTL}

local rr1_ttl0 = {name={'Foo'}, rdata='Bar', rtype=DUMMY_TYPE, ttl=0}

local rr2_cf = {name={'Foo'}, rdata='Baz', rtype=DUMMY_TYPE2, rclass=CLASS_IN, cache_flush=true, ttl=DUMMY_TTL}

local rr_dummy_a_cf_nottl = {name={'dummy', 'local'},
                             rdata_a='1.2.3.4', 
                             rtype=dns_const.TYPE_A,
                             rclass=dns_const.CLASS_IN,
                             cache_flush=true,
}

local rr_dummy_a_cf = {name={'dummy', 'local'},
                       rdata_a='1.2.3.4', 
                       rtype=dns_const.TYPE_A,
                       rclass=dns_const.CLASS_IN,
                       cache_flush=true,
                       ttl=DUMMY_TTL,
}


local rr_dummy_a2_cf = {name={'dummy', 'local'},
                         rdata_a='1.2.3.5', 
                         rtype=dns_const.TYPE_A,
                         rclass=dns_const.CLASS_IN,
                         cache_flush=true,
                         ttl=DUMMY_TTL,
}

local rr_dummy_aaaa_cf = {name={'dummy', 'local'},
                          rdata_aaaa='f80:dead:beef::1234', 
                          rtype=dns_const.TYPE_AAAA,
                          rclass=dns_const.CLASS_IN,
                          cache_flush=true,
                          ttl=DUMMY_TTL,
}

local rr_foo_a_cf = {name={'foo', 'local'},
                       rdata_a='192.168.1.1', 
                       rtype=dns_const.TYPE_A,
                       rclass=dns_const.CLASS_IN,
                       cache_flush=true,
                       ttl=DUMMY_TTL,
}


local msg1 = dnscodec.dns_message:encode{
   h={
      -- MUST s18.4 - ignore id in responses
      id=123,
      
      qr=true,
   }, 
   an={rr1}}
--mst.a(dnscodec.dns_message:decode(msg1).h.id > 0)

local msg1_ttl0 = dnscodec.dns_message:encode{h={qr=true},
                                              an={rr1_ttl0}}

local msg1_cf = dnscodec.dns_message:encode{h={qr=true},
                                            an={rr1_cf}}

local msg_dummy_aaaa_cf = dnscodec.dns_message:encode{
   h={qr=true},
   an={rr_dummy_aaaa_cf},
                                                     }

local msg_dummy_a_a2_cf = dnscodec.dns_message:encode{
   h={qr=true},
   an={rr_dummy_a_cf, rr_dummy_a2_cf},
                                                     }

local query1 = dnscodec.dns_message:encode{
   h={
      -- to check s18.5
      id=DUMMY_ID1,
      -- check s18.8 
      opcode=3,
      -- check s18.9/10
      aa=true,
   }, 

   qd={{name={'Foo'}, qtype=DUMMY_TYPE}},
                                          }

local query1_rcode = dnscodec.dns_message:encode{
   -- MUST IGNORE s18.25/26   
   h={rcode=1},
   qd={{name={'Foo'}, qtype=DUMMY_TYPE},
   }
                                                }
local query1_qu = dnscodec.dns_message:encode{
   -- to check s18.5
   h={id=DUMMY_ID2}, 
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qu=true}},
                                          }

local query1_type_any_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=dns_const.TYPE_ANY, qu=true}},
                                                 }

local query1_class_any_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qclass=dns_const.CLASS_ANY, qu=true}},
                                                       }

local query1_type_nomatch_qu = dnscodec.dns_message:encode{
   -- to check s18.5
   h={id=DUMMY_ID3}, 
   qd={{name={'Foo'}, qtype=(DUMMY_TYPE+1), qu=true}},
                                                          }

local query1_class_nomatch_qu = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qclass=(dns_const.CLASS_IN+1), qu=true}},
                                                          }

local query1_kas = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qu=true}},
   an={rr1},
                                          }

rr1_low_ttl = mst.table_copy(rr1)
rr1_low_ttl.ttl = math.floor(rr1.ttl / 4)

local query1_kas_low_ttl = dnscodec.dns_message:encode{
   qd={{name={'Foo'}, qtype=DUMMY_TYPE, qu=true}},
   an={rr1_low_ttl},
                                          }

local query_dummy_local_a = dnscodec.dns_message:encode{
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_A}},
                                                       }


local query_dummy_local_qu = dnscodec.dns_message:encode{
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_ANY, qu=true}},
                                                        }

local q_dummy_a = {name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_A, qu=true}

local query_dummy_local_a_qu = dnscodec.dns_message:encode{
   qd={q_dummy_a},
                                          }

local query_dummy_local_a_kas_a_qu = dnscodec.dns_message:encode{
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_A, qu=true}},
   an={rr_dummy_a_cf},
                                          }

local query_dummy_local_a_kas_aaaa_qu = dnscodec.dns_message:encode{
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_A, qu=true}},
   an={rr_dummy_aaaa_cf},
                                          }

local query_dummy_local_any_tc = dnscodec.dns_message:encode{
   h={tc=true},
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_ANY}},
                                                            }


local query_kas_dummy_a_cf = dnscodec.dns_message:encode{
   an={rr_dummy_a_cf},
                                                        }

local query_dummy_local_aaaa_qu = dnscodec.dns_message:encode{
   qd={{name=rr_dummy_a_cf.name, qtype=dns_const.TYPE_AAAA, qu=true}},
                                          }

local q_foo_a = {name=rr_foo_a_cf.name, qtype=dns_const.TYPE_A, qu=true}

local query_dummy_foo_qu = dnscodec.dns_message:encode{
   qd={q_dummy_a, q_foo_a},
                                                      }

local query_foo_local_a = dnscodec.dns_message:encode{
   qd={{name=rr_foo_a_cf.name, qtype=dns_const.TYPE_A}},
                                                        }

describe("mdns", function ()
            local DUMMY_IP='dummy'
            local DUMMY_IF='eth1'
            local DUMMY_SRC=DUMMY_IP .. '%' .. DUMMY_IF
            local n, dsm, mdns, dummy, s
            before_each(function ()
                           n = dneigh.dneigh:new{}
                           dsm = mydsm:new{e=n, 
                                           port_offset=42536,
                                           create_callback=create_node_callback}
                           mdns = dsm:create_node{rid='n1', class=_mdns}
                           dummy = dsm:create_node{rid='dummy', 
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

            function run_rr_states(orr, expected_states)
                  mdns:run()
                  mdns:insert_if_own_rr('eth1', orr)
                  --mdns:recvfrom(msg, 'dead:beef::1%eth0', mdns_const.PORT)
                  local rr = mdns:get_if('eth1').own:values()[1]
                  local dummies = 0
                  for k, v in pairs(expected_states)
                  do
                     if not v then dummies = dummies + 1 end
                  end
                  while (mst.table_count(expected_states) - dummies) > 0
                  do
                     mst.d('in state', rr.state)
                     mst.a(expected_states[rr.state])
                     expected_states[rr.state] = nil
                     local nt = mdns:next_time()
                     mst.a(nt)
                     dsm:set_time(nt)
                     mdns:run()
                  end
                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()
                  mst.d('run_rr_states done')
            end
            it("works (CF=~unique) #cf", function ()
                  expected_states = {[mdns_if.STATE_P1]=true,
                                     [mdns_if.STATE_P2]=true,
                                     [mdns_if.STATE_P3]=true,
                                     [mdns_if.STATE_PW]=true,
                                     [mdns_if.STATE_A1]=true,
                                     [mdns_if.STATE_A2]=true,
                  }
                  run_rr_states(rr1_cf, expected_states)
                  dsm:assert_receiveds_eq(5)
                  dsm:clear_receiveds()

                  mst.d('probe+announce completed')

                  -- some time can pass (so that we skip multicast
                  -- re-broadcast time limitations)
                  dsm:advance_time(2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'propagation did not terminate')

                  -- check that we get instant response to a query
                  -- SHOULD reply immediately, s6.10/11
                  mst.d('checking that unique answer => instant reply')
                  mdns:recvfrom(query1, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_queries_done()
                  dsm:assert_receiveds_eq(0)
                  mdns:run()
                  dsm:assert_receiveds_eq(1)

                  dummy:sanity_check_last_multicast_response()

                  -- make sure cache flush bit is set
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an > 0)
                  mst.a(msg.an[1].cache_flush)

                  dsm:clear_receiveds()

                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:assert_receiveds_eq(0)

                        end)
            it("works (!CF=~shared) #ncf", function ()
                  expected_states = {[mdns_if.STATE_P1]=false,
                                     [mdns_if.STATE_P2]=false,
                                     [mdns_if.STATE_P3]=false,
                                     [mdns_if.STATE_PW]=false,
                                     [mdns_if.STATE_A1]=true,
                                     [mdns_if.STATE_A2]=true,
                  }
                  run_rr_states(rr1, expected_states)
                  -- make sure we get only 2 messages to dummy
                  dsm:assert_receiveds_eq(2)
                  dsm:clear_receiveds()

                  -- make sure we get replies to ok requests
                  mdns:recvfrom(query1_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_unicast_response(DUMMY_ID2)
                  -- make sure we don't have NSEC (s6.32, sort of)
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an == 1)
                  dsm:clear_receiveds()

                  -- but not to invalid ones
                  -- MUST s6.3 (=> no reply as not unique)
                  mst.d('checking invalid qus')
                  mdns:recvfrom(query1_type_nomatch_qu, DUMMY_SRC, mdns_const.PORT)
                  mdns:recvfrom(query1_class_nomatch_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)

                  -- some time can pass (so that we skip multicast
                  -- re-broadcast time limitations)
                  mst.d('advancing 2 seconds')
                  dsm:advance_time(2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we get _delayed_ response 
                  -- to shared stuff (see 6.10/11)
                  mst.d('checking that shared answer => delayed reply')
                  mdns:recvfrom(query1, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_multicast_response()
                  -- make sure we don't have NSEC (s6.32, sort of)
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an == 1)
                  dsm:clear_receiveds()

                  -- make sure that if we receive the message, with
                  -- smaller ttl (in this case, 0)
                  -- s6.45 MUST
                  mst.d('checking rttl < ttl / 2 case')
                  dsm:advance_time(2)
                  mdns:recvfrom(msg1_ttl0, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_multicast_response()
                  local msg = dummy:get_last_msg()
                  mst.a(msg.an and #msg.an > 0 and msg.an[1].ttl > 0, 'invalid received', msg)
                  dsm:clear_receiveds()

                  
                  -- make sure we get final ttl=0 message eventually
                  mst.d('waiting for final ttl=0')
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:assert_receiveds_eq(1)
                  -- make sure it looks sane
                  dummy:sanity_check_last_multicast_response()
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an > 0 and msg.an[1].ttl == 0)
                        end)

            it("works - 2x CF #rr2", function ()
                  -- 
                  mdns:insert_if_own_rr('eth1', rr1_cf)
                  mdns:insert_if_own_rr('eth1', rr2_cf)
                  dsm:wait_receiveds_counts(1)
                  -- now we have one query (=probe) packet to analyze.
                  -- let's!
                  dummy:sanity_check_last_probe()

                  dsm:wait_receiveds_counts(5)
                  dummy:sanity_check_last_announce()

                  -- clear receiveds
                  dsm:clear_receiveds()

                  -- receive non-matching type,
                  -- we should get back reply anyway, with
                  -- NSEC stating that there are two supported types
                  mdns:recvfrom(query1_type_nomatch_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)
                  mdns:run()
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_multicast_response(DUMMY_ID3)
                  --dummy:sanity_check_last_multicast_response()
                  mst.d('received is', dummy.received[1])
                  local msg = dummy:get_last_msg()

                  -- MUST s6.3 (=> reply as we're authoritative)
                  -- MUST s6.4 => wrong types cause NSEC
                  -- s6.23 MUST reply with NSEC
                  mst.a(#msg.an == 1)
                  local rr = msg.an[1]
                  mst.a(rr.rtype == dns_const.TYPE_NSEC)
                  mst.a(mst.repr_equal(rr.rdata_nsec.ndn, {'Foo'}),
                       'ndn missing/wrong', rr)
                  -- s6.30 - NSEC bits MUST NOT contain NSEC
                  mst.a(mst.repr_equal(rr.rdata_nsec.bits, 
                                       {DUMMY_TYPE, DUMMY_TYPE2}),
                        'bits missing/wrong', rr)
                  dsm:clear_receiveds()


                  -- finally, even at end of ttl, there should be no
                  -- messages
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:assert_receiveds_eq(0)
                   end)

            function check_f(f, t, cnt)
               local msg = dummy:get_last_msg()
               local dcnt = (cnt or 1)
               if t
               then
                  mst.a(#msg[f] == dcnt, 'not desired cnt', cnt, msg[f])
                  mst.a(msg[f][1].rtype == t)
               else
                  mst.a(#msg[f] == 0, 'something in', f, msg[f])
               end
            end

            it("handles A/AAAA correctly #a", function ()
                  -- A, AAAA record for dummy.local
                  mdns:insert_if_own_rr('eth1', rr_dummy_a_cf)
                  mdns:insert_if_own_rr('eth1', rr_dummy_aaaa_cf)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_probe()
                  dsm:wait_receiveds_counts(5)
                  dummy:sanity_check_last_announce()
                  dsm:clear_receiveds()

                  -- s6.35 SHOULD check for placing A/AAAA complements

                  -- Now we can interact with them, hooray. Let's use
                  -- QU packets to ask about A, AAAA, and any.
                  -- All should result in 2 results, if no KAS.
                  -- (One in an, one in ar).
                  mst.d('a) AAAA request => both')
                  mdns:recvfrom(query_dummy_local_aaaa_qu, DUMMY_SRC, mdns_const.PORT+1)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_legacy_unicast_response()
                  local msg = dummy:get_last_msg()
                  check_f('an', dns_const.TYPE_AAAA)
                  check_f('ar', dns_const.TYPE_A)
                  dsm:clear_receiveds()

                  mst.d('b) A request => both')
                  mdns:recvfrom(query_dummy_local_a_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_unicast_response()
                  local msg = dummy:get_last_msg()
                  check_f('an', dns_const.TYPE_A)
                  check_f('ar', dns_const.TYPE_AAAA)
                  dsm:clear_receiveds()

                  -- With KAS, if it hits an, no reply at all
                  mst.d('c) A request with A KAS => nop')
                  mdns:recvfrom(query_dummy_local_a_kas_a_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)

                  -- With KAS, if it hits ar, no ar but an
                  mst.d('d) A request with AAAA kas => A')
                  mdns:recvfrom(query_dummy_local_a_kas_aaaa_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_unicast_response()
                  local msg = dummy:get_last_msg()
                  check_f('an', dns_const.TYPE_A)
                  check_f('ar')
                  dsm:clear_receiveds()

                  -- Delayed KAS case (which we do only for multicast)
                  -- s7.3 MUST
                  dsm:advance_time(2)
                  dsm:run_nodes(123)
                  mdns:recvfrom(query_dummy_local_any_tc, DUMMY_SRC, mdns_const.PORT)
                  dsm:advance_time(0.2)
                  dsm:run_nodes(123)
                  dsm:assert_receiveds_eq(0)
                  -- no tc bit -> should receive answer 'soon'
                  mdns:recvfrom(query_kas_dummy_a_cf, DUMMY_SRC, mdns_const.PORT)
                  dsm:advance_time(0.15)
                  dsm:run_nodes(123)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_multicast_response()
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an == 2)
                  local vt = {[dns_const.TYPE_NSEC]=true,
                              [dns_const.TYPE_AAAA]=true}
                  mst.a(vt[msg.an[1].rtype], 'invalid rtype', msg.an[1])
                  mst.a(vt[msg.an[2].rtype], 'invalid rtype', msg.an[2])
                  check_f('ar')
                  dsm:clear_receiveds()

                   end)
            it("handles multiple queries correctly #mq", function ()
                  mdns:insert_if_own_rr('eth1', rr_dummy_a_cf)
                  mdns:insert_if_own_rr('eth1', rr_foo_a_cf)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_probe()
                  dsm:wait_receiveds_counts(5)
                  dummy:sanity_check_last_announce()
                  dsm:clear_receiveds()

                  mst.d('a) receive foo A QU => one resp')
                  mdns:recvfrom(query_dummy_foo_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_unicast_response()

                  -- s6.38 MUST handle multiple queries
                  check_f('an', dns_const.TYPE_A, 2)

                  -- s6.36 SHOULD - NSEC if no AAAA available
                  check_f('ar', dns_const.TYPE_NSEC, 2)
                  dsm:clear_receiveds()

                  dsm:advance_time(2)

                  -- similarly, even if we get queries
                  -- in a while within each other,
                  -- we should get replies in one message
                  -- s6.40/41 SHOULD test
                  mst.d('b) receive 2x dummy q, and then foo q => one resp')
                  mdns:recvfrom(query_dummy_local_a, DUMMY_SRC, mdns_const.PORT)
                  mdns:recvfrom(query_dummy_local_a, DUMMY_SRC, mdns_const.PORT)
                  mdns:recvfrom(query_foo_local_a, DUMMY_SRC, mdns_const.PORT)
                  dsm:assert_receiveds_eq(0)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_multicast_response()
                  check_f('an', dns_const.TYPE_A, 2)
                  check_f('ar', dns_const.TYPE_NSEC, 2)
                  dsm:clear_receiveds()

                  -- advance few seconds, make sure we have nothing else coming
                  dsm:advance_time(2)
                  dsm:run_nodes(123)
                  dsm:assert_receiveds_eq(0)

                   end)

            it("handles non-repeating query ok #nrq", function ()
                  -- set up initial state
                  mst.d('initial setup')

                  mdns:insert_if_own_rr('eth1', rr_dummy_a_cf)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_probe()
                  dsm:wait_receiveds_counts(5)
                  dummy:sanity_check_last_announce()
                  dsm:clear_receiveds()

                  -- then, ask about the same record on IF, just for fun
                  mst.d('sending query')
                  mdns:query('eth1', q_dummy_a)
                  -- s5.6 SHOULD (delay 20-120ms)
                  dsm:assert_receiveds_eq(0)
                  dsm:advance_time(0.2)
                  mdns:run()
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_multicast_query()
                  local msg = dummy:get_last_msg()
                  mst.a(#msg.an > 0, 'no KAS?!?', msg)
                  dsm:clear_receiveds()

                  mst.d('expecting no traffic for awhile')
                  dsm:advance_time(700)
                  mdns:run()
                  dsm:assert_receiveds_eq(0)
                                                      end
              )
            it("handles repeating query ok #rq", function ()
                  -- set up initial state
                  mst.d('initial setup')

                  mdns:insert_if_own_rr('eth1', rr_dummy_a_cf)
                  dsm:wait_receiveds_counts(1)
                  dummy:sanity_check_last_probe()
                  dsm:wait_receiveds_counts(5)
                  dummy:sanity_check_last_announce()
                  dsm:clear_receiveds()

                  -- then, ask about the same record on IF, just for fun
                  mst.d('sending query')
                  mdns:start_query('eth1', q_dummy_a)
                  dsm:assert_receiveds_eq(0)
                  dsm:advance_time(0.2)
                  mdns:run()
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_multicast_query()
                  dsm:clear_receiveds()

                  -- s5.3-5 MUSTs about delayed behavior
                  -- (rather lazy test, but close enough..)

                  -- we should get 8 within <1000 seconds, but
                  -- in more than 255 seconds (2^8-1), or well,
                  -- sum 2^i where i=0-7 (+ some spare fuzz factor)
                  dsm:wait_receiveds_counts(8)
                  local delta = dsm:get_elapsed_time()
                  mst.a(delta > 255, 'too short delta', delta)
                  mst.a(delta < 1000, 'too long delta', delta)
                  mdns:stop_query('eth1', q_dummy_a)
                  dsm:clear_receiveds()

                  -- wait 200 seconds, should receive no further messages
                  dsm:advance_time(200)
                  mdns:run()
                  dsm:assert_receiveds_eq(0)
                   end)

            it("asks for queried things #refresh", function ()
                  mdns:recvfrom(msg1_cf, DUMMY_SRC, mdns_const.PORT)
                  local q_rr1 = {name=rr1_cf.name,
                                 qtype=DUMMY_TYPE,
                                 qclass=dns_const.CLASS_ANY,
                  }
                  -- s5.8 SHOULD
                  -- (and inverse of s5.9 MUST NOT test, sigh)
                  mdns:query('eth1', q_rr1, true)
                  -- just jump forward in time, and wait for a bit
                  dsm:advance_time(DUMMY_TTL * 3 / 4)
                  dsm:wait_receiveds_counts(8)
                  -- look at the receiveds - they should contain two types of
                  -- messages: generic ones (qclass=ANY), and specific ones (qclass=..)
                  local c1 = 0
                  local c2 = 0
                  for i=0, 7
                  do
                     local m = dummy:get_last_msg(i)
                     for i, q in ipairs(m.qd)
                     do
                        if q.qclass == dns_const.CLASS_ANY
                        then
                           c1 = c1 + 1
                        else
                           c2 = c2 + 1
                        end
                     end
                  end
                  mst.a(c1 > 0, 'no class_anys (=repeating)')
                  mst.a(c2 > 0, 'no specific class questions (=refresh)')

                  dsm:clear_receiveds()
                  -- stop query
                  mdns:stop_query('eth1', q_rr1)
                  
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:assert_receiveds_eq(0)
                                                   end)
            it("(non-solicited) - accepts multicast, drops unicast", function ()
                  -- partial s6.19-20 - legacy unicast case
                  mdns:recvfrom(msg1_cf, DUMMY_SRC, mdns_const.PORT)
                  local c = mdns:get_if("eth1")
                  mst.a(c.cache:count() == 1)
                  -- something received via legacy unicast should NOT
                  -- be in cache
                  mdns:recvfrom(msg_dummy_aaaa_cf, DUMMY_SRC, mdns_const.PORT+1)
                  mst.a(c.cache:count() == 1)
                   end)
            it("handles cache flush on per rr set, not per rr basis #rrset", function ()
                  mdns:recvfrom(msg_dummy_a_a2_cf, DUMMY_SRC, mdns_const.PORT)
                  local c = mdns:get_if("eth1")
                  local cnt = c.cache:count()
                  mst.a(cnt == 2, 'both records not there?', cnt)
                   end)
            
            it("won't immediately destroy ttl0 stuff", function ()
                  -- s9.3 SHOULD

                  mdns:recvfrom(msg1, DUMMY_SRC, mdns_const.PORT)

                  local c = mdns:get_if("eth1")
                  local cnt = c.cache:count()
                  mst.a(cnt == 1, 'record not there?', cnt)
                  
                  mdns:recvfrom(msg1_ttl0, DUMMY_SRC, mdns_const.PORT)
                  local cnt = c.cache:count()
                  mst.a(cnt == 1, 'record not there?', cnt)

                  -- but in two seconds, it should be gone
                  dsm:advance_time(2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'propagation did not terminate')

                  local cnt = c.cache:count()
                  mst.a(cnt == 0, 'record there?', cnt)

                   end)

            it("keeps own no-ttl records forever #fe", function ()
                  mdns:insert_if_own_rr('eth1', rr_dummy_a_cf_nottl)
                  dsm:wait_receiveds_counts(5)
                  dsm:clear_receiveds()
                  
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:advance_time(12345)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'propagation did not terminate')
                  dsm:assert_receiveds_eq(0)

                  -- let's make sure we still get response if we ask for it
                  mdns:recvfrom(query_dummy_local_a_qu, DUMMY_SRC, mdns_const.PORT+1)
                  dsm:assert_receiveds_eq(1)
                  dummy:sanity_check_last_unicast_response()
                  local msg = dummy:get_last_msg()
                  check_f('an', dns_const.TYPE_A)
                  check_f('ar', dns_const.TYPE_NSEC)
                  dsm:clear_receiveds()

                   end)
end)

describe("degenerate multi-mdns setup (mdns_ospf)", function ()
            local DUMMY_IP='dummy2'
            local DUMMY_IF='id2'
            local DUMMY_SRC=DUMMY_IP .. '%' .. DUMMY_IF
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
                  function not_interested()
                     return
                  end
                  mdns1 = dsm:create_node{rid='n1'}
                  mdns1.interested_in_cached = not_interested
                  mdns2 = dsm:create_node{rid='n2'}
                  mdns2.interested_in_cached = not_interested
                  mdns3 = dsm:create_node{rid='n3'}
                  mdns3.interested_in_cached = not_interested
                  dummy1 = dsm:create_node{rid='dummy1', dsm=dsm, dummy=true}
                  dummy2 = dsm:create_node{rid='dummy2', dsm=dsm, dummy=true}
                  dummy3 = dsm:create_node{rid='dummy3', dsm=dsm, dummy=true}
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
                          local r = dsm:run_nodes_and_advance_time(123)
                          mst.a(r, 'propagation did not terminate')

                          -- ensure that state is really empty
                          for i, mdns in ipairs{mdns1, mdns2, mdns3}
                          do
                             local oc = mdns:own_count()
                             mst.a(oc == 0, 'should have no own entries left', oc, mdns.rid)
                             -- s5.7 SHOULD 
                             local cc = mdns:cache_count()
                             mst.a(cc == 0, 'should have no cache entries left', cc, mdns.rid)
                          end

                          dsm:done()
                       end)
            it("works #multi", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_cf, 'dead:beef::1%id1', mdns_const.PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  dsm:assert_receiveds_eq(0, 5, 5)

                   end)
            it("won't propagate 0 ttl stuff", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1_ttl0, 'dead:beef::1%id1', mdns_const.PORT)
                  local r = dsm:run_nodes_and_advance_time(123)
                  mst.a(r, 'propagation did not terminate')

                  -- make sure we got _something_ in each dummy
                  -- (1 shouldn't, as it's same interface)
                  dsm:assert_receiveds_eq(0, 0, 0)
                   end)
            it("shared records - 2x announce, 1x ttl=0 #shb", function ()
                  local r = dsm:run_nodes(3)
                  mst.a(r, 'basic run did not terminate')

                  mdns1:recvfrom(msg1, 'dead:beef::1%id1', mdns_const.PORT)
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
                  mdns1:recvfrom(msg1, 'dead:beef::1%id1', mdns_const.PORT)

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
                  dsm:clear_receiveds()

                  -- couple of different cases

                  -- a) unicast should work always (even when stuff
                  -- has just been multicast)
                  -- dummy2 asks => dummy2 gets (3 times)
                  -- s5.20 SHOULD
                  mst.d('a) 2x unicast query')

                  -- s6.46 MUST handle legacy unicast's
                  mdns2:recvfrom(query1, DUMMY_SRC, mdns_const.PORT + 1)
                  mdns2:recvfrom(query1, DUMMY_SRC, mdns_const.PORT + 1)
                  dsm:wait_receiveds_counts(0, 2, 0)
                  -- make sure it is unicast
                  dummy2:assert_received_to(DUMMY_IP)
                  dummy2:sanity_check_last_unicast_response(DUMMY_ID1)
                  dsm:clear_receiveds()

                  -- s5.18 SHOULD
                  mst.d('a1) qu')
                  mdns2:recvfrom(query1_qu, DUMMY_SRC, mdns_const.PORT)
                  dsm:wait_receiveds_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  dummy2:assert_received_to(DUMMY_IP)
                  dummy2:sanity_check_last_unicast_response(DUMMY_ID2)

                  -- b) multicast should NOT work right after
                  -- multicast was received (0.2 to account for
                  -- processing delay)
                  mst.d('b) no-direct-multicast-reply')
                  dsm:clear_receiveds()
                  mdns2:recvfrom(query1, DUMMY_SRC, mdns_const.PORT)
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:wait_receiveds_counts(0, 0, 0)

                  -- c) multicast should work 'a bit' after
                  mst.d('c) advancing time')
                  dsm:clear_receiveds()
                  dsm:advance_time(2)

                  -- try first with rcode set - shouldn't do a thing
                  -- (s18.27)
                  mdns2:recvfrom(query1_rcode, DUMMY_SRC, mdns_const.PORT)
                  local r = dsm:run_nodes(123)
                  dsm:assert_receiveds_eq(0, 0, 0)
                  dsm:assert_queries_done()

                  mdns2:recvfrom(query1, DUMMY_SRC, mdns_const.PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  dsm:assert_receiveds_eq(0, 0, 0)
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 1, 0)
                  dummy2:sanity_check_last_multicast_response()
                  dsm:clear_receiveds()

                  -- move time forward bit
                  dsm:advance_time(0.7)

                  -- yet another query should not provide result
                  -- within 0,8sec (1sec spam limit)
                  -- s6.21 MUST
                  mdns2:recvfrom(query1, DUMMY_SRC, mdns_const.PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:advance_time(0.2)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 0, 0)

                  -- d) KAS should work
                  -- => no answer if known
                  -- s7.1 MUST - KAS ttl >= real ttl / 2
                  dsm:advance_time(2)
                  mst.d('d) KAS 1')
                  mdns2:recvfrom(query1_kas, DUMMY_SRC, mdns_const.PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  -- no immediate reply - should wait bit before replying
                  dsm:assert_receiveds_eq(0, 0, 0)
                  -- but eventually we should get what we want
                  dsm:advance_time(0.6)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 0, 0)


                  mst.d('d) KAS 2')
                  -- s7.2 MUST - KAS ttl < real ttl / 2
                  mdns2:recvfrom(query1_kas_low_ttl, DUMMY_SRC, mdns_const.PORT)
                  local r = dsm:run_nodes(123)
                  mst.a(r, 'did not terminate')
                  dsm:assert_receiveds_eq(0, 1, 0)
                  dsm:clear_receiveds()

                  -- e) check that different queries work
                  -- as expected; that is, type=all results something,
                  -- but no type => no answer
                  -- s6.2
                  dsm:advance_time(2)
                  mdns2:recvfrom(query1_type_any_qu, DUMMY_SRC, mdns_const.PORT)
                  mdns2:recvfrom(query1_class_any_qu, DUMMY_SRC, mdns_const.PORT)
                  mdns2:recvfrom(query1_class_any_qu, DUMMY_SRC, mdns_const.PORT)
                  mdns2:recvfrom(query1_type_nomatch_qu, DUMMY_SRC, mdns_const.PORT)
                  mdns2:recvfrom(query1_class_nomatch_qu, DUMMY_SRC, mdns_const.PORT)

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
                  mdns2:recvfrom(query1_qu, DUMMY_SRC, mdns_const.PORT)
                  -- can't be instant
                  dsm:assert_receiveds_eq(0, 0, 0)
                  dsm:wait_receiveds_counts(0, 1, 0)
                  mst.d('received', dummy2.received)
                  -- make sure it is unicast
                  dummy2:sanity_check_last_multicast_response()
                   end)
end)

describe("realistic multi-mdns setup (mdns_ospf)", function ()
            local DUMMY_IP='dummy2'
            local DUMMY_IF='id2'
            local DUMMY_SRC=DUMMY_IP .. '%' .. DUMMY_IF
            local n
            local d
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
                  dsm = mydsm:new{e=n, port_offset=43576,
                                  create_callback=create_node_callback}
                  mdns1 = dsm:create_node{rid='n1'}
                  mdns2 = dsm:create_node{rid='n2'}
                  mdns3 = dsm:create_node{rid='n3'}

                  d = dospf:new{dsm=dsm, rid='dospf'}
                  dsm:add_node(d)
                  d:register_to_skvs()
                  
                  -- in this topology, dummies are replaced by real
                  -- mdns implementations, using the non-ospf-aware
                  -- mdns code; the network is also NOT pathological,
                  -- that is, only only one owner per network
                  -- (one with highest name)

                  dummy1 = dsm:create_node{rid='dummy1', class=_mdns}
                  dummy2 = dsm:create_node{rid='dummy2', class=_mdns}
                  dummy3 = dsm:create_node{rid='dummy3', class=_mdns}
                  dummy1.skv:set(elsa_pa.OSPF_LAP_KEY, {
                                    {ifname='dummyif', owner=true}
                                                       })
                  dummy2.skv:set(elsa_pa.OSPF_LAP_KEY, {
                                    {ifname='dummyif', owner=true}
                                                       })
                  dummy3.skv:set(elsa_pa.OSPF_LAP_KEY, {
                                    {ifname='dummyif', owner=true}
                                                       })

                  local s = mdns1.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='id1', owner=true},
                           {ifname='i123'},
                           {ifname='i12'},
                           {ifname='i13'},
                                              })

                  local s = mdns2.skv
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='id2', owner=true},
                           {ifname='i213'},
                           {ifname='i21', owner=true},
                           {ifname='i23'},
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
                          local r = dsm:run_nodes_and_advance_time(123)
                          mst.a(r, 'propagation did not terminate')

                          -- ensure that state is really empty
                          for i, mdns in ipairs{dummy1, dummy2, dummy3, 
                                                mdns1, mdns2, mdns3}
                          do
                             local oc = mdns:own_count()
                             mst.a(oc == 0, 'should have no own entries left', oc, mdns.rid)
                             -- s5.7 SHOULD 
                             local cc = mdns:cache_count()
                             mst.a(cc == 0, 'should have no cache entries left', cc, mdns.rid)
                          end

                          dsm:done()
                       end)

            function wait_counts_base(getter, ...)
               local tl = {mdns1, mdns2, mdns3}
               local l = {...}
               function count_desired()
                  for i, v in ipairs(l)
                  do
                     local d = tl[i]
                     local v2 = getter(d)
                     mst.d('checking count', i, v, v2)
                     --mst.a(v2 <= v, 'v2 > v', i, v2, v, d)

                     if v2 ~= v
                     then
                        return false
                     end
                  end
                  return true
               end
               if count_desired() then return end
               local r = dsm:run_nodes_and_advance_time(123, 
                                                         {until_callback=count_desired})
               mst.a(r, 'propagation did not terminate')
               mst.a(count_desired(), 'dummies not in desired state')

            end
            function wait_cache_counts(...)
               wait_counts_base(function (mdns)
                                   return mdns:cache_count()
                                end, ...)
            end
            function wait_own_counts(...)
               wait_counts_base(function (mdns)
                                   return mdns:own_count()
                                end, ...)
            end

            it("works #skv", function ()
                  -- setup + teardown test

                  -- insert rr with ttl to own of dummy1; it should
                  -- propagate eventually to dummy2 and dummy3
                  dummy1:insert_if_own_rr('dummyif', rr1_cf)

                  -- each dummy should receive this, eventually
                  wait_cache_counts(1, 0, 0)
                  wait_own_counts(0, 2, 4)

                  -- eventually, cache and own entries should also disappear
                  wait_cache_counts(0, 0, 0)
                  wait_own_counts(0, 0, 0)
                   end)
end)
