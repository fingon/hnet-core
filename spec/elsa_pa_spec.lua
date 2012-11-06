#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Oct  3 11:49:00 2012 mstenber
-- Last modified: Tue Nov  6 08:12:23 2012 mstenber
-- Edit time:     241 min
--

require 'mst'
require 'busted'
require 'elsa_pa'
require 'skv'
require 'ssloop'

module("elsa_pa_spec", package.seeall)

local _delsa = require 'delsa'
delsa = _delsa.delsa

local usp_dead_tlv = codec.usp_ac_tlv:encode{prefix='dead::/16'}
local jari_tlv_type = codec.ac_tlv:new_subclass{tlv_type=123}
local broken_jari_tlv = jari_tlv_type:new{}:encode{body=''}

local rhf_low_tlv = codec.rhf_ac_tlv:encode{body=string.rep("a", 32)}
local rhf_high_tlv = codec.rhf_ac_tlv:encode{body=string.rep("z", 32)}
local valid_end='::/64'

local FAKE_DNS_ADDRESS='dead::1'
local FAKE_DNS_SEARCH='dummy.local'

-- override timeouts so that this won't take forever..
elsa_pa.LAP_DEPRACATE_TIMEOUT=0.01
elsa_pa.LAP_EXPIRE_TIMEOUT=0.01

local PD_PREFIX_KEY=elsa_pa.PD_SKVPREFIX .. elsa_pa.PREFIX_KEY
local PD_DNS_KEY=elsa_pa.PD_SKVPREFIX .. elsa_pa.DNS_KEY
local PD_DNS_SEARCH_KEY=elsa_pa.PD_SKVPREFIX .. elsa_pa.DNS_SEARCH_KEY
local PD_NH_KEY=elsa_pa.PD_SKVPREFIX .. elsa_pa.NH_KEY

function ensure_skv_usp_has_nh(s, should_nh, should_if)
   local uspkey = s:get(elsa_pa.OSPF_USP_KEY)
   mst.a(#uspkey >= 1)
   -- make sure it has nh+ifname set
   local uspo = uspkey[1]
   should_if = should_if ~= nil and should_if or should_nh
   mst.a(not uspo.nh == not should_nh, 'nh state unexpected - not', should_nh)
   mst.a(not uspo.ifname == not should_if, 'ifname state unexpected - not', should_if)
end

describe("elsa_pa [one node]", function ()
            local e, s, ep, usp_added, asp_added
            before_each(function ()
                           e = delsa:new{iid={mypid={{index=42, 
                                                      name='eth0'},
                                                     {index=123,
                                                      name='eth1'}}}, 
                                         hwf={mypid='foo'},
                                         lsas={},
                                         routes={r1={nh='foo', ifname='fooif'}},
                                         assume_connected=true,
                                         disable_autoroute=true,
                                        }
                           s = skv.skv:new{long_lived=true, port=31337}
                           s:set(elsa_pa.DISABLE_SKVPREFIX .. 'eth0', 1)
                           s:set(elsa_pa.DISABLE_V4_SKVPREFIX .. 'eth0', 2)
                           ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid='mypid',
                                                    new_prefix_assignment=0}
                           e:add_router(ep)

                           -- run once, and make sure we get to pa.add_or_update_usp
                           usp_added = false
                           asp_added = false
                           ssloop.inject_snitch(ep.pa, 'add_or_update_usp', function ()
                                                   usp_added = true
                                                                            end)
                           ssloop.inject_snitch(ep.pa, 'add_or_update_asp', function ()
                                                   asp_added = true
                                                                            end)

                        end)
            after_each(function ()
                          -- make sure that the ospf-usp looks sane
                          local uspl = s:get(elsa_pa.OSPF_USP_KEY) or {}
                          mst.a(not usp_added or #uspl>0, 'invalid uspl - nothing?', uspl)
                          for i, usp in ipairs(uspl)
                          do
                             mst.a(type(usp) == 'table')
                             mst.a(type(usp.prefix) == 'string')
                             mst.a(string.find(usp.prefix, '::'), 'invalid prefix', usp)
                             -- XXX - add other checks once multihoming implemented
                          end
                          local lapl = s:get(elsa_pa.OSPF_LAP_KEY) or {}
                          for i, lap in ipairs(lapl)
                          do
                             mst.a(type(lap) == 'table')
                             mst.a(type(lap.ifname) == 'string')
                             mst.a(type(lap.prefix) == 'string')
                             mst.a(string.sub(lap.prefix, -#valid_end) == valid_end, 'invalid prefix', lap.prefix)

                          end
                          local ifl = s:get(elsa_pa.OSPF_IFLIST_KEY) or {}
                          for i, v in ipairs(ifl)
                          do
                             mst.a(type(v) == 'string')
                          end

                          -- cleanup
                          ep:done()
                          s:done()
                          e:done()

                          -- make sure cleanup really was clean
                          local r = ssloop.loop():clear()
                          mst.a(not r, 'event loop not clear')

                       end)
            it("works minimally #base", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)
                  mst.a(not asp_added)

                  -- make sure 'static' flag was propagated to eth0
                  mst.a(ep.pa.ifs[42].disable == 1)
                  mst.a(ep.pa.ifs[42].disable_v4 == 2)


                  -- then, we add the usp (from someone else than us)
                  e.lsas = {r1=usp_dead_tlv, jari=broken_jari_tlv}
                  ep:ospf_changed()

                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)

                  -- and then we should get our own asp back too
                  asp_added = false
                  usp_added = false
                  ep:run()
                  mst.a(usp_added)
                  -- XXX mst.a(asp_added)

                  -- test that if we remove interfaces, it should not
                  -- remove lap's from skv (otherwise there is a
                  -- problem, if and when OSPF implementation's
                  -- interface report is shaky)
                  e.iid = {}
                  ep:run()
                  local lapkey = s:get(elsa_pa.OSPF_LAP_KEY)
                  mst.a(#lapkey > 0)
                  
                  -- nonlocal usp, and we have route info -> should
                  -- have nh+ifname set
                  ensure_skv_usp_has_nh(s, true)

                  -- now, get rid of the usp => eventually, the lap
                  -- should disappear
                  e.lsas = {}
                  ep:ospf_changed()
                  mst.a(ep.pa.lap:count() > 0)
                  ssloop.loop():loop_until(function ()
                                              asp_added = false
                                              usp_added = false
                                              ep:run()
                                              local done = ep.pa.lap:count() == 0
                                              return done
                                           end)
                  
                  -- now locally assigned prefixes should be gone too
                  mst.a(ep.pa.lap:count() == 0)
                  -- and usps should have been gone even before that
                  mst.a(ep.pa.usp:count() == 0)


                                        end)

            it("works even if routes become available later #later", function ()
                  -- in this case, the route information was not being
                  -- propagated to USP if route information became
                  -- available _AFTER_ the usp. let's see if this is still true
                  local old_routes = e.routes
                  e.routes = {}
                  e.lsas = {r1=usp_dead_tlv}
                  ep:ospf_changed()

                  -- add
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)

                  ensure_skv_usp_has_nh(s, false)

                  -- add route info
                  e.routes = old_routes
                  ep:ospf_changed() -- XXX - hopefully it will trigger this too!
                  ep:run()
                  ensure_skv_usp_has_nh(s, true)

                  -- make sure no DNS IF we don't have DNS info
                  local v = s:get(elsa_pa.OSPF_DNS_KEY)
                  mst.a(not v or #v == 0, 'DNS set?!?', v)

                  local v = s:get(elsa_pa.OSPF_DNS_SEARCH_KEY)
                  mst.a(not v or #v == 0, 'DNS search set?!?', v)
                   end)

            it("also works via skv configuration - but no ifs! #noi", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)
                  mst.a(not asp_added)

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  s:set(elsa_pa.PD_IFLIST_KEY, {'eth0', 'eth1'})
                  s:set(PD_PREFIX_KEY .. 'eth0', 
                        -- prefix[,valid]
                        {'dead::/16'}
                       )
                  s:set(PD_PREFIX_KEY .. 'eth1', 
                        -- just the string should also work
                        'beef::/16'
                       )

                  s:set(PD_DNS_KEY .. 'eth1',
                        FAKE_DNS_ADDRESS)
                  
                  s:set(PD_DNS_SEARCH_KEY .. 'eth1',
                        FAKE_DNS_SEARCH)
                  
                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added, 'asp was added?!?')

                  -- but without ifs, no asp assignment
                  ep:run()
                  --mst.a(not asp_added)
                  -- (even the PD IF should get a prefix now 11/04)
                  -- XXX mst.a(asp_added)

                  -- make sure DNS gets set IF we have DNS info
                  local v = s:get(elsa_pa.OSPF_DNS_KEY)
                  mst.a(mst.repr_equal(v, {FAKE_DNS_ADDRESS}), 'got', v)

                  local v = s:get(elsa_pa.OSPF_DNS_SEARCH_KEY)
                  mst.a(mst.repr_equal(v, {FAKE_DNS_SEARCH}))

                                                        end)

            it("also works via skv configuration #skv", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)
                  mst.a(not asp_added)

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  s:set(elsa_pa.PD_IFLIST_KEY, {'eth0', 'eth2'})
                  s:set(PD_PREFIX_KEY .. 'eth0', 
                        -- prefix[,valid]
                        {'dead::/16'}
                       )
                  s:set(PD_PREFIX_KEY .. 'eth2', 
                        -- just the string should also work
                        'beef::/16'
                       )
                  
                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)

                  -- and then we should get our own asp back too
                  asp_added = false
                  usp_added = false
                  ep:run(ep)
                  -- XXX mst.a(asp_added, 'asp not added?!?')
                  mst.a(usp_added)

                  -- local usp -> should NOT have nh (if not configured to SKV)
                  ensure_skv_usp_has_nh(s, false, true)

                  -- now, we add the NH info -> it should be available too
                  s:set(PD_NH_KEY .. 'eth0', 
                        'fe80:1234:2345:3456:4567:5678:6789:789a')
                  s:set(PD_NH_KEY .. 'eth2', 
                        'fe80:1234:2345:3456:4567:5678:6789:789b')

                  ep:run(ep)
                  ensure_skv_usp_has_nh(s, true, true)


                                                        end)

            it("6rd also works via skv configuration #skv2", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)
                  mst.a(not asp_added)

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  s:set(elsa_pa.SIXRD_SKVPREFIX .. elsa_pa.PREFIX_KEY .. 
                        elsa_pa.SIXRD_DEV,
                        -- prefix[,valid]
                        {'dead::/16'}
                       )
                  
                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)
                                                             end)

            it("duplicate detection works - smaller", function ()
                  e.lsas={mypid=rhf_low_tlv,
                          r1=usp_dead_tlv}
                  ep:ospf_changed()
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)
                  mst.a(not e.rid_changed)

                                                      end)

            it("duplicate detection works - greater", function ()
                  e.lsas={mypid=rhf_high_tlv,
                          r1=usp_dead_tlv}
                  ep:ospf_changed()
                  ep:run()
                  mst.a(not usp_added)
                  mst.a(not asp_added)
                  mst.a(e.rid_changed)
                                                      end)

            it("duplicate detection works - greater, oob lsa", function ()
                  local dupe = {rid='mypid',
                                body=rhf_high_tlv}
                  ep:check_conflict(dupe)
                  mst.a(e.rid_changed)
                                                      end)

                               end)

describe("elsa_pa 2-node", function ()
            local e, skv1, skv2, ep1, ep2
            
            before_each(function ()
                  local base_lsas = {r1=usp_dead_tlv}
                  e = delsa:new{iid={ep1={{index=42, name='eth0'},
                                                {index=123, name='eth1'}}, 
                                     ep2={{index=43,name='eth0'},
                                          {index=124, name='eth1'}}},
                                hwf={ep1='foo',
                                     ep2='bar'},
                                assume_connected=true,
                                lsas=base_lsas}
                  e:connect_neigh('ep1', 123, 'ep2', 124)
                  skv1 = skv.skv:new{long_lived=true, port=31338}
                  skv2 = skv.skv:new{long_lived=true, port=31339}
                  ep1 = elsa_pa.elsa_pa:new{elsa=e, skv=skv1, rid='ep1'}
                  ep2 = elsa_pa.elsa_pa:new{elsa=e, skv=skv2, rid='ep2'}
                  e:add_router(ep1)
                  e:add_router(ep2)

                        end)
            it("2 sync state ok #mn", function ()
                  --mst.d_xpcall(function ()

                  -- store DNS information
                  skv1:set(PD_DNS_KEY .. 'eth1', FAKE_DNS_ADDRESS)
                  skv1:set(PD_DNS_SEARCH_KEY .. 'eth1', FAKE_DNS_SEARCH)

                  -- run once, and make sure we get to pa.add_or_update_usp

                  for i=1,3
                  do
                     mst.d('running iter', i)
                     ep1:run()
                     ep2:run()
                  end


                  -- 3 asps -> each should have 3 asps + 2 lap
                  -- (2 ifs per box)
                  for i, ep in ipairs({ep1, ep2})
                  do
                     for i, asp in ipairs(ep.pa.asp:values())
                     do
                        mst.a(string.sub(asp.ascii_prefix, -#valid_end) == valid_end, 'invalid prefix', asp)

                     end
                     mst.a(ep.pa.asp:count() == 3)
                     mst.a(ep.pa.lap:count() == 2)
                  end

                  local v = skv2:get(elsa_pa.OSPF_DNS_KEY)
                  mst.a(mst.repr_equal(v, {FAKE_DNS_ADDRESS}))

                  local v = skv2:get(elsa_pa.OSPF_DNS_SEARCH_KEY)
                  mst.a(mst.repr_equal(v, {FAKE_DNS_SEARCH}))

                  -- cleanup
                  ep1:done()
                  ep2:done()
                  skv1:done()
                  skv2:done()

                  e:done()

                  -- make sure cleanup really was clean
                  local r = ssloop.loop():clear()
                  mst.a(not r, 'event loop not clear')

                                  end)
            --                    end)
                              end)

describe("elsa_pa bird7-ish", function ()
            local e, skvs, eps, local_time
            function connect_nodes()
                  -- wire up the routers like in bird7
                  -- e.g. HOME = cpe[0], bird1[0], bird2[0]
                  e:connect_neigh('bird0', 42, 
                                  'bird1', 42,
                                  'bird2', 42)
                  -- BIRD1
                  e:connect_neigh('bird1', 43, 
                                  'bird3', 42)
                  -- BIRD2, 3 aren't connected anywhere
                  

                  -- sanity check - all 4 nodes should be connected
                  local t = e:get_connected('bird0')
                  mst.a(t:count() == 4, 'connect_neigh or get_connected not working', t)
            end
            function run_nodes(iters, clear_busy)
               -- run nodes up to X iterations, or when none of them
               -- don't want to run return true if stop condition was
               -- encountered before iters iterations
               for i=1,iters
               do
                  mst.d('iteration', i)
                  for i, ep in ipairs(mst.array_randlist(eps))
                  do
                     ep:run()
                     if clear_busy then ep.pa.busy = nil end
                  end
                  local l = 
                     eps:filter(function (ep) return ep:should_run(ep.ospf_changes) end)
                  if #l == 0
                  then
                     return true
                  end
               end
            end
            before_each(function ()
                  -- it has 4 real bird nodes;
                  -- [1] is the one connected to outside world
                  -- (named bird0 to retain naming consistency)
                  skvs = mst.array:new{}
                  eps = mst.array:new{}
                  iids = {}
                  hwfs = {}
                  e = delsa:new{iid=iids, hwf=hwfs}
                  for i=0,3
                  do
                     local name = 'bird' .. tostring(i)
                     iids[name] = {{index=42, name='eth0'},
                                   {index=43, name='eth1'}}
                     hwfs[name] = name
                     local s = skv.skv:new{long_lived=true, port=42420+i}
                     local ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid=name}
                     skvs:insert(s)
                     eps:insert(ep)
                     e:add_router(ep)
                  end
                        end)

            function ensure_same()
                  local ep1 = eps[4]
                  local pa1 = ep1.pa
                  for i, ep in ipairs(eps)
                  do
                     local pa = ep.pa
                     mst.a(pa.usp:count() == pa1.usp:count(), 'usp', pa, pa1)
                     mst.a(pa.asp:count() == pa1.asp:count(), 'asp', pa, pa1)

                     -- lap count can be bigger, if there's redundant
                     -- allocations
                     --mst.a(pa.lap:count() == pa1.lap:count(), 'lap', pa, pa1)
                  end
            end

            function ensure_counts()
                  local ep1 = eps[4]
                  local pa1 = ep1.pa
                  -- make sure that view sounds sane
                  -- 2 USP (ULA, IPv4)
                  mst.a(pa1.usp:count() == 2, 'usp', pa1.usp)

                  -- # links * 2 AF IPv4+USP
                  -- BIRD1-3, HOME, ISP
                  local links = 5
                  mst.a(pa1.asp:count() == links * 2, 'wrong asp count', pa1, pa1.asp, pa1.asp:count())
                  -- 2 if * USP,IPv4 [cannot be more, highest rid]
                  local laps = pa1.lap:values()
                  local alaps = laps:filter(function (lap) return lap.assigned end)
                  mst.a(#alaps == 2 * 2, 'wrong lap count', pa1, alaps)
            end
            after_each(function ()
                          for i, ep in ipairs(eps)
                          do
                             ep:done()
                          end
                          for i, s in ipairs(skvs)
                          do
                             s:done()
                          end

                          -- make sure cleanup really was clean
                          local r = ssloop.loop():clear()
                          mst.a(not r, 'event loop not clear')
                       end)
            it("instant connection #inst", function ()
                  connect_nodes()
                  
                  mst.a(run_nodes(10, true), 'did not halt in time')

                  ensure_same()

                  ensure_counts()
                  
                   end)

            it("delayed connection #delay", function ()
                  
                  mst.a(run_nodes(2, true), 'did not halt in time')

                  connect_nodes()
                  
                  mst.a(run_nodes(10), 'did not halt in time')

                  ensure_same()

                  ensure_counts()
                  
                   end)


            it("survive net burps #burp", function ()
                  mst.a(run_nodes(2, true), 'did not halt in time')

                  for i=1,3
                  do
                  connect_nodes()
                  
                  mst.a(run_nodes(10), 'did not halt in time')

                  ensure_same()

                  ensure_counts()
                  
                  e:clear_connections()

                  mst.a(run_nodes(2), 'did not halt in time')

                  end

                   end)

                           end)
