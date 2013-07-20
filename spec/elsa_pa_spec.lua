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
-- Last modified: Sat Jul 20 21:06:49 2013 mstenber
-- Edit time:     493 min
--

require 'mst'
require 'mst_test'
require 'busted'
require 'elsa_pa'
require 'skv'
require 'ssloop'

module("elsa_pa_spec", package.seeall)


local _dsm = require 'dsm'
local dsm = _dsm.dsm

local _delsa = require 'delsa'
local delsa = _delsa.delsa
local dummy_if_table = _delsa.dummy_if_table

local usp_dead_tlv = ospf_codec.usp_ac_tlv:encode{prefix='dead::/16'}
local json_dead_lifetime_tlv = ospf_codec.json_ac_tlv:encode{table={[elsa_pa.JSON_USP_INFO_KEY]={{prefix='dead::/16', [elsa_pa.PREFERRED_KEY]=300, [elsa_pa.VALID_KEY]=600}}}}
local jari_tlv_type = ospf_codec.ac_tlv:new_subclass{tlv_type=123}
local broken_jari_tlv = jari_tlv_type:new{}:encode{body=''}

local rhf_low_tlv = ospf_codec.rhf_ac_tlv:encode{body=string.rep("a", 32)}
local rhf_high_tlv = ospf_codec.rhf_ac_tlv:encode{body=string.rep("z", 32)}
local valid_end='::/64'

local FAKE_DNS_ADDRESS='dead::1'
local FAKE_DNS_SEARCH='dummy.local'

local SIXRD_DEV='6rd'

-- override timeouts so that this won't take forever..
elsa_pa.LAP_DEPRACATE_TIMEOUT=0.01
elsa_pa.LAP_EXPIRE_TIMEOUT=0.01

function ensure_skv_usp_has_nh(s, should_nh, should_if)
   local uspkey = s:get(elsa_pa.OSPF_USP_KEY)
   mst.a(#uspkey >= 1)
   -- make sure it has nh+ifname set
   local uspo = uspkey[1]
   should_if = should_if ~= nil and should_if or should_nh
   mst.a(not uspo.nh == not should_nh, 'nh state unexpected - not', should_nh)
   mst.a(not uspo.ifname == not should_if, 'ifname state unexpected - not', should_if)
end

function dsm_run_with_clear_busy_callback(dsm, o)
   o:run()
   o.pa.busy = nil
end

function create_elsa_callback(o)
   return elsa_pa.elsa_pa:new{elsa=o.sm.e, skv=o.skv, rid=o.rid,
                              time=o.time, if_table=dummy_if_table,
                              pa_config={},
                             }
end

function ensure_dsm_same(self)
   local ep1 = self:get_nodes()[1]
   local pa1 = ep1.pa
   for i, ep in ipairs(self:get_nodes())
   do
      local pa = ep.pa
      mst.a(pa.usp:count() == pa1.usp:count(), 'usp', pa, pa1)
      mst.a(pa.asp:count() == pa1.asp:count(), 'asp', pa, pa1)
      
      -- lap count can be bigger, if there's redundant
      -- allocations
      --mst.a(pa.lap:count() == pa1.lap:count(), 'lap', pa, pa1)
   end
end

describe("elsa_pa [one node, no config]", function ()
            local ep
            local s
            it("does not do much w/o pa_config", function ()
                  s = skv.skv:new{long_lived=true, port=31399}
                  ep = elsa_pa.elsa_pa:new{elsa=true, if_table=true, 
                                           skv=s,
                                           rid='myrid'}
                  ep:run()
                  ep:lsa_changed{rid=ep.rid, type=1}
                  ep:lsa_changed{rid=false, type=1}
                  ep:lsa_changed{rid=ep.rid, type=elsa_pa.AC_TYPE}
                  ep:lsa_changed{rid=false, type=elsa_pa.AC_TYPE}
                  mst.a(not ep.pa)
                  ep:done()
                  s:done()
                   end)
             end)

describe("elsa_pa [one node]", function ()
            local e, s, ep, usp_added, asp_added
            local t
            function inject_snitches()
               usp_added = false
               asp_added = false
               mst_test.inject_snitch(ep.pa, 'add_or_update_usp', function ()
                                         usp_added = true
                                                                end)
               mst_test.inject_snitch(ep.pa, 'add_or_update_asp', function ()
                                       asp_added = true
                                                                end)
            end
            before_each(function ()
                           e = delsa:new{iid={myrid={{index=42, 
                                                      name='eth0'},
                                                     {index=123,
                                                      name='eth1'}}}, 
                                         hwf={myrid='foo'},
                                         lsas={},
                                         routes={r1={nh='foo', ifname='fooif'}},
                                         assume_connected=true,
                                         disable_autoroute=true,
                                        }
                           s = skv.skv:new{long_lived=true, port=31337}
                           s:set(elsa_pa.DISABLE_SKVPREFIX .. 'eth0', 1)
                           s:set(elsa_pa.DISABLE_V4_SKVPREFIX .. 'eth0', 2)
                           s:set(elsa_pa.PA_CONFIG_SKV_KEY, {[pa.CONFIG_DISABLE_IPV4]=true})
                           t = 1234
                           ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid='myrid',
                                                    originate_min_interval=0,
                                                    new_prefix_assignment=0,
                                                    time=function ()
                                                       return t
                                                    end,
                                                    if_table=dummy_if_table,
                                                   }
                           e:add_node(ep)
                           mst.a(ep.time() == t)
                           mst.a(ep.pa.time() == t)
                           inject_snitches()
                        end)
            after_each(function ()
                          mst.a(not asp_added, 'no rempte ASPs with 1 node?')

                          -- make sure that the ospf-usp looks sane
                          local uspl = s:get(elsa_pa.OSPF_USP_KEY) or {}
                          mst.a(not usp_added or #uspl>0, 
                                'invalid uspl - nothing?', uspl)
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

                  -- make sure 'static' flag was propagated to eth0
                  mst.a(ep.pa.ifs[42].disable == 1)
                  mst.a(ep.pa.ifs[42].disable_v4 == 2)


                  -- then, we add the usp (from someone else than us)
                  e.lsas = {r1=usp_dead_tlv, jari=broken_jari_tlv}
                  ep:ospf_changed()

                  ep:run()
                  mst.a(usp_added)

                  -- and then we should get our own asp back too
                  usp_added = false
                  ep:run()
                  mst.a(usp_added)

                  -- make sure reconfigure operation also works
                  ep:reconfigure_pa{disable_ula=true}
                  inject_snitches()
                  -- should be cleared in inject_snitches
                  mst.a(not usp_added)
                  -- but now running should result in fresh usp being added
                  ep:run()
                  mst.a(usp_added)
                  -- run it few more times, for luck 
                  ep:run()
                  ep:run()
                  mst.a(not ep:should_publish{})


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
                  mst.a(ep.pa.lap:count() > 0)
                  e.lsas = {}
                  ep:ospf_changed()
                  while ep.pa.lap:count() ~= 0
                  do
                     ep:run()
                     t = t + 1
                  end

                  usp_added = false
                  
                  -- now locally assigned prefixes should be gone too
                  mst.a(ep.pa.lap:count() == 0)
                  -- and usps should have been gone even before that
                  mst.a(ep.pa.usp:count() == 0)

                  mst.a(not ep:should_publish{})

                                        end)

            it("works even if routes become available later #later", function ()
                  -- in this case, the route information was not being
                  -- propagated to USP if route information became
                  -- available _AFTER_ the usp. let's see if this is still true
                  local old_routes = e.routes
                  e.routes = {}
                  e.lsas = {r1=usp_dead_tlv .. json_dead_lifetime_tlv}

                  ep:ospf_changed()

                  -- add
                  ep:run()
                  mst.a(usp_added)

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

                  -- ensure that if we advance time, we shouldn't re-publish lsa
                  local old_lsa = e.lsas.myrid
                  mst.a(old_lsa)

                  mst.d('advancing time')
                  t = t + 17
                  ep:ospf_changed()
                  ep:run()
                  local new_lsa = e.lsas.myrid
                  mst.a(new_lsa and old_lsa == new_lsa)

                                                                     end)

            it("also works via skv configuration - but no ifs! #noi", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  --s:set(elsa_pa.IFLIST_KEY, {'eth0', 'eth1'})
                  s:set(elsa_pa.PD_SKVPREFIX .. 'eth0', 
                        {
                           {
                              [elsa_pa.PREFIX_KEY]='dead::/16',
                              [elsa_pa.PREFERRED_KEY]=t + 300,
                              [elsa_pa.VALID_KEY]=t + 600,
                              [elsa_pa.DNS_KEY]=FAKE_DNS_ADDRESS,
                              [elsa_pa.DNS_SEARCH_KEY]=FAKE_DNS_SEARCH,
                           },
                        }
                       )
                  
                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added, 'no USP added')

                  -- but without ifs, no asp assignment
                  ep:run()
                  -- (even the PD IF should get a prefix now 11/04)

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

                  local rel_pref = 300
                  local rel_valid = 600

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  --s:set(elsa_pa.IFLIST_KEY, {'eth0', 'eth2'})
                  s:set(elsa_pa.PD_SKVPREFIX .. 'eth0', 
                        {
                           {[elsa_pa.PREFIX_KEY]='dead::/16',
                            [elsa_pa.PREFERRED_KEY]=rel_pref,
                            [elsa_pa.VALID_KEY]=rel_valid,
                           },
                        }
                       )

                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added, 'no USP added')

                  -- and then we should get our own asp back too
                  usp_added = false
                  ep:run(ep)
                  mst.a(usp_added)

                  -- local usp -> should NOT have nh (if not configured to SKV)
                  ensure_skv_usp_has_nh(s, false, true)

                  -- now, we add the NH info -> it should be available too
                  s:set(elsa_pa.PD_SKVPREFIX .. 'eth0', 
                        {
                           {[elsa_pa.PREFIX_KEY]='dead::/16',
                            [elsa_pa.PREFERRED_KEY]=rel_pref,
                            [elsa_pa.VALID_KEY]=rel_valid,
                            [elsa_pa.NH_KEY]='fe80:1234:2345:3456:4567:5678:6789:789a'},
                        }
                       )

                  ep:run(ep)
                  ensure_skv_usp_has_nh(s, true, true)

                  -- ensure that if we advance time, we shouldn't re-publish lsa
                  local old_lsa = e.lsas.myrid
                  mst.a(old_lsa)

                  mst.d('advancing time')
                  t = t + 17
                  ep:ospf_changed()
                  ep:run()
                  local new_lsa = e.lsas.myrid
                  mst.a(new_lsa and old_lsa == new_lsa, 'lsa mismatch due to moving time, eep')
                                                        end)

            it("6rd also works via skv configuration #6skv", function ()
                  -- in the beginning, should only get nothing
                  ep:run()
                  mst.a(not usp_added)

                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  s:set(elsa_pa.TUNNEL_SKVPREFIX .. SIXRD_DEV,
                        {
                           {prefix='dead::/16'},
                        }
                       )

                  -- should not be necessary - automatically should
                  -- occur once TUNNEL_SKVPREFIX is added
                  --s:set(elsa_pa.TUNNEL_SKVPREFIX .. elsa_pa.IFLIST_KEY, {SIXRD_DEV})
                  
                  -- make sure it's recognized as usp
                  ep:run()
                  mst.a(usp_added, 'no USP added in 6rd config')
                  mst_test.assert_repr_equal(ep.pa.usp:count(), 1)

                  -- advance time quite a bit - otherwise, busylooping
                  -- may call run, while we want to make sure that
                  -- just adding the artificial interface will in and
                  -- of itself cause call of pa:run()
                  t = t + 1234
                  ep:run()
                  ep:run()
                  -- ULA should show up too
                  mst_test.assert_repr_equal(ep.pa.usp:count(), 2,
                                             ep.pa.usp)

                  t = t + 10
                  -- ok, let's add _second_ one. we should have 2 usps then.
                  -- now we fake it that we got prefix from pd
                  -- (skv changes - both interface list, and pd info)
                  s:set(elsa_pa.TUNNEL_SKVPREFIX .. SIXRD_DEV .. '-2',
                        {
                           {prefix='beef::/16'},
                        }
                       )
                  mst.d('calling run with second tunnel')
                  ep:run()
                  mst_test.assert_repr_equal(ep.pa.usp:count(), 3,
                                             ep.pa.usp)
                  

                                                             end)

            it("duplicate detection works - dupe smaller", function ()
                  e.lsas={myrid=rhf_low_tlv,
                          r1=usp_dead_tlv}
                  ep:ospf_changed()
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not e.rid_changed)

                                                           end)

            it("duplicate detection works - dupe greater #dupe", function ()
                  e.lsas={myrid=rhf_high_tlv,
                          r1=usp_dead_tlv}
                  ep:ospf_changed()
                  ep:run()
                  mst.a(e.rid_changed)
                  mst.a(not usp_added)
                                                                 end)

            it("duplicate detection works - greater, oob lsa", function ()
                  local dupe = {rid='myrid',
                                body=rhf_high_tlv}
                  ep:check_conflict(dupe)
                  mst.a(e.rid_changed)
                                                               end)

                               end)

describe("elsa_pa 2-node", function ()
            local sm
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
                           sm = dsm:new{e=e, port_offset=31338,
                                        create_callback=create_elsa_callback}
                           ep1 = sm:create_node{rid='ep1'}
                           skv1 = sm.skvs[1]
                           ep2 = sm:create_node{rid='ep2'}
                           skv2 = sm.skvs[2]
                        end)
            after_each(function ()
                          sm:done()
                       end)
            it("2 syncs state over long time too #long", function ()
                  -- store DNS information
                  skv1:set(elsa_pa.PD_SKVPREFIX .. 'eth0',
                           {
                              --prefix
                              {[elsa_pa.PREFIX_KEY] = 'dead::/16',
                               [elsa_pa.PREFIX_CLASS_KEY] = 42},
                              -- and some random other info
                              {[elsa_pa.DNS_KEY] = FAKE_DNS_ADDRESS},
                              {[elsa_pa.DNS_SEARCH_KEY] = FAKE_DNS_SEARCH},
                           }
                          )
                  -- 1234 seconds onward, max of 123 iterations
                  -- (this should cover any funny business)
                  sm:run_nodes_until_delta(123, 1234)
                  ensure_sane()
                  e:clear_connections()
                  sm:run_nodes_until_delta(123, 30)
                  e:connect_neigh('ep1', 123, 'ep2', 124)
                  sm:run_nodes_until_delta(123, 1234)
                  ensure_sane()
                   end)

            function ensure_sane()
                  -- 3 asps -> each should have 3 asps + 2 lap
                  -- (2 ifs per box)
                  for i, ep in ipairs({ep1, ep2})
                  do
                     mst.a(ep.pa.rname, 'has to have router name', i, ep)
                     for i, asp in ipairs(ep.pa.asp:values())
                     do
                        mst.a(string.sub(asp.ascii_prefix, -#valid_end) == valid_end, 'invalid prefix', asp)

                     end
                     mst.a(ep.pa.asp:count() == 2, 
                           'invalid ep.pa.asp', i,
                           ep.pa.asp)
                     for i, lap in ipairs(ep.pa.lap:values())
                     do
                        --mst.a(lap[elsa_pa.PREFIX_CLASS_KEY] == 42, 
                        --'no pclass set')
                     end
                  end

                  -- router naems should be different
                  mst.a(ep1.pa.rname ~= ep2.pa.rname, 
                        'router name same?!?', ep1.pa.rname)


                  -- ep1 is connected to ISP on one interface =>
                  -- shouldn't be AP there
                  mst.a(ep1.pa.lap:count() == 1, ep1.pa.lap)

                  -- ep2 should have AP on each interface
                  mst.a(ep2.pa.lap:count() == 2, ep2.pa.lap)
            end
            it("2 sync state ok #mn", function ()
                  ep1.originate_min_interval=0
                  ep2.originate_min_interval=0
                  --mst.d_xpcall(function ()

                  -- store DNS information
                  local rel_pref = 123
                  local rel_valid = 234

                  skv1:set(elsa_pa.PD_SKVPREFIX .. 'eth0',
                           {
                              --prefix
                              {[elsa_pa.PREFIX_KEY] = 'dead::/16',
                               [elsa_pa.PREFIX_CLASS_KEY] = 42,
                               [elsa_pa.PREFERRED_KEY] = rel_pref,
                               [elsa_pa.VALID_KEY] = rel_valid,
                              },
                              -- and some random other info
                              {[elsa_pa.DNS_KEY] = FAKE_DNS_ADDRESS},
                              {[elsa_pa.DNS_SEARCH_KEY] = FAKE_DNS_SEARCH},
                           }
                          )

                  -- set the static domain here
                  local DUMMYDOMAIN={'xxx', 'domain'}
                  local DUMMYDOMAIN2={'yyy', 'domain'}
                  skv1:set(elsa_pa.STATIC_HP_DOMAIN_KEY, DUMMYDOMAIN)

                  local STATICZONE={name='bar.com',
                                    ip='1.2.3.4'}
                  local DUMMYZONE={name='r2.foo.com',
                                   ip='1.2.3.4'}
                  skv1:set(elsa_pa.STATIC_HP_ZONES_KEY, {STATICZONE})
                  skv1:set(elsa_pa.HP_MDNS_ZONES_KEY, {DUMMYZONE}) 

                  -- run once, and make sure we get to pa.add_or_update_usp
                  mst.d('starting run post-config')


                  mst.a(sm:run_nodes(123), 'did not halt in time')

                  ensure_sane()

                  for i, s in ipairs{skv1, skv2}
                  do
                     local uspl = s:get(elsa_pa.OSPF_USP_KEY)
                     for i, usp in ipairs(uspl)
                     do
                        mst.a(usp.pclass, 'no pclass in ospf-usp', i, usp)
                        local pref = usp[elsa_pa.PREFERRED_KEY]
                        local exp = rel_pref
                        mst.a(pref == exp, 'pref mismatch', pref, exp)
                        local val = usp[elsa_pa.VALID_KEY]
                        local exp = rel_valid
                        mst.a(val == exp, 'valid mismatch', val, exp)
                     end
                  end
                  for i, s in ipairs{skv1, skv2}
                  do
                     local lapl = s:get(elsa_pa.OSPF_LAP_KEY)
                     for i, lap in ipairs(lapl)
                     do
                        mst.a(lap.pclass, 'no pclass in ospf-lap', i, lap)
                        local pref = lap[elsa_pa.PREFERRED_KEY]
                        local exp = rel_pref
                        mst.a(pref == exp, 'preference mismatch', pref, exp)
                        local val = lap[elsa_pa.VALID_KEY]
                        local exp = rel_valid
                        mst.a(val == exp, 'valid mismatch', val, exp)
                     end
                  end

                  local v = skv2:get(elsa_pa.OSPF_DNS_KEY)
                  local exp = {FAKE_DNS_ADDRESS}
                  mst_test.assert_repr_equal(v, exp, 'propagated dns key', skv2)

                  local v = skv2:get(elsa_pa.OSPF_DNS_SEARCH_KEY)
                  mst.a(mst.repr_equal(v, {FAKE_DNS_SEARCH}))

                  -- make sure the 'hp-domain' for both nodes is 
                  -- what we set by hand
                  local v = skv1:get(elsa_pa.OSPF_HP_DOMAIN_KEY)
                  mst.a(mst.repr_equal(v, DUMMYDOMAIN), 
                        'not same domain (local)')
                  local v = skv2:get(elsa_pa.OSPF_HP_DOMAIN_KEY)
                  mst.a(mst.repr_equal(v, DUMMYDOMAIN), 
                        'not same domain (remote)', v, DUMMYDOMAIN)

                  local v = skv1:get(elsa_pa.OSPF_HP_ZONES_KEY)
                  local e = {STATICZONE}
                  mst.a(mst.repr_equal(v, e), 'not same', v, e)

                  local v = skv2:get(elsa_pa.OSPF_HP_ZONES_KEY)
                  local e = {STATICZONE, DUMMYZONE}
                  mst.a(mst.repr_equal(v, e), 'not same', v, e)

                  -- make sure that just changing hp-domain will also
                  -- propagate it 'fast'
                  skv1:set(elsa_pa.STATIC_HP_DOMAIN_KEY, DUMMYDOMAIN2)
                  mst.a(sm:run_nodes(3), 'did not halt in time')
                  
                  local v = skv1:get(elsa_pa.OSPF_HP_DOMAIN_KEY)
                  mst_test.assert_repr_equal(v, DUMMYDOMAIN2,
                                             'not same domain (local)')
                  local v = skv2:get(elsa_pa.OSPF_HP_DOMAIN_KEY)
                  mst_test.assert_repr_equal(v, DUMMYDOMAIN2, 
                                             'not same domain (remote)')
                                      end)
                           end)

describe("elsa_pa bird7-ish", function ()
            local e, sm
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
            before_each(function ()
                           -- it has 4 real bird nodes;
                           -- [1] is the one connected to outside world
                           -- (named bird0 to retain naming consistency)
                           iids = {}
                           hwfs = {}
                           e = delsa:new{iid=iids, hwf=hwfs}
                           sm = dsm:new{e=e, port_offset=42420,
                                        create_callback=create_elsa_callback}
                           for i=0,3
                           do
                              local name = 'bird' .. tostring(i)
                              iids[name] = {{index=42, name='eth0'},
                                            {index=43, name='eth1'}}
                              hwfs[name] = name
                              local ep = sm:create_node{rid=name}
                              ep.originate_min_interval=0
                           end
                        end)

            after_each(function ()
                          sm:done()
                       end)
            function ensure_counts()
               mst.a(#sm:get_nodes() == 4, 'not 4 eps', sm:get_nodes())

               local ep1 = sm:get_nodes()[4]
               mst.a(ep1)
               
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
            it("instant connection #inst", function ()
                  connect_nodes()
                  
                  mst.a(sm:run_nodes(10, dsm_run_with_clear_busy_callback),
                        'did not halt in time')

                  ensure_dsm_same(sm)

                  ensure_counts()
                  
                                           end)

            it("delayed connection #delay", function ()
                  
                  mst.a(sm:run_nodes(4, dsm_run_with_clear_busy_callback), 
                        'did not halt in time')

                  connect_nodes()
                  
                  mst.a(sm:run_nodes(10, nil, true), 'did not halt in time')

                  ensure_dsm_same(sm)

                  ensure_counts()
                  
                                            end)


            it("survive net burps #burp", function ()
                  mst.a(sm:run_nodes(4, dsm_run_with_clear_busy_callback), 
                        'did not halt in time')

                  for i=1,3
                  do
                     connect_nodes()
                     
                     mst.a(sm:run_nodes(10, nil, true), 'did not halt in time')

                     ensure_dsm_same(sm)

                     ensure_counts()
                     
                     e:clear_connections()

                     mst.a(sm:run_nodes(2), 'did not halt in time')

                  end

                                          end)

                              end)
