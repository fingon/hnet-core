#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Oct  3 11:49:00 2012 mstenber
-- Last modified: Wed Oct  3 23:26:44 2012 mstenber
-- Edit time:     53 min
--

require 'mst'
require 'busted'
require 'elsa_pa'
require 'skv'
require 'ssloop'

delsa = mst.create_class{class='delsa'}

function delsa:iterate_lsa(f, criteria)
   for rid, body in pairs(self.lsas)
   do
      f{rid=rid, body=body}
   end
end

function delsa:iterate_if(rid, f)
   for i, v in ipairs(self.iid[rid] or {})
   do
      f(v)
   end
end

function delsa:originate_lsa(lsa)
   self:a(lsa.type == elsa_pa.AC_TYPE)
   self.lsas[lsa.rid] = lsa.body
end

describe("elsa_pa", function ()
            it("can be created", function ()
                  local base_lsas = {r1=codec.usp_ac_tlv:encode{prefix='dead::/16'}}
                  local e = delsa:new{iid={mypid={42, 123}}, 
                                      lsas=base_lsas}
                  local skv = skv.skv:new{long_lived=true, port=31337}
                  local ep = elsa_pa.elsa_pa:new{elsa=e, skv=skv, rid='mypid'}

                  -- run once, and make sure we get to pa.add_or_update_usp
                  local usp_added = false
                  local asp_added = false
                  ssloop.inject_snitch(ep.pa, 'add_or_update_usp', function ()
                                          usp_added = true
                                                                end)
                  ssloop.inject_snitch(ep.pa, 'add_or_update_asp', function ()
                                          asp_added = true
                                                                end)
                  ep:run()
                  mst.a(usp_added)
                  mst.a(not asp_added)

                  asp_added = false
                  usp_added = false
                  ep:run(ep)
                  mst.a(asp_added)
                  mst.a(usp_added)

                  -- cleanup
                  ep:done()
                  skv:done()
                  e:done()

                  -- make sure cleanup really was clean
                  local r = ssloop.loop():clear()
                  mst.a(not r, 'event loop not clear')

                                 end)
            it("2 sync state ok", function ()
                  mst.d_xpcall(function ()

                  local base_lsas = {r1=codec.usp_ac_tlv:encode{prefix='dead::/16'}}
                  local e = delsa:new{iid={ep1={42, 123}, 
                                           ep2={43,123}},
                                      lsas=base_lsas}
                  local skv1 = skv.skv:new{long_lived=true, port=31338}
                  local skv2 = skv.skv:new{long_lived=true, port=31339}
                  local ep1 = elsa_pa.elsa_pa:new{elsa=e, skv=skv1, rid='ep1'}
                  local ep2 = elsa_pa.elsa_pa:new{elsa=e, skv=skv2, rid='ep2'}

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
                     mst.a(ep.pa.asp:count() == 3)
                     mst.a(ep.pa.lap:count() == 2)
                  end

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
                    end)
                    end)
