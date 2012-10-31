#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pa_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct  1 11:49:11 2012 mstenber
-- Last modified: Wed Oct 31 15:17:28 2012 mstenber
-- Edit time:     241 min
--

require "busted"
local _pa = require "pa"
require 'mst'
require 'dneigh'

module("pa_spec", package.seeall)

-- 3 globals used to keep track of stuff
o = nil
pa = nil
timeouts = mst.set:new()

dummy_lap = _pa.lap:new_subclass{class='dummy_lap'}

function dummy_lap:start_depracate_timeout()
   assert(not timeouts[self])
   timeouts:insert(self)
end

function dummy_lap:stop_depracate_timeout()
   assert(timeouts[self])
   timeouts:remove(self)
end

ospf = dneigh.dneigh:new_subclass{class='ospf'}

function ospf:init()
   self.asa = self.asa or {}
   self.asp = self.asp or {}
   self.usp = self.usp or {}
   self.iif = self.iif or {}
   self.ridr = self.ridr or {}
   self.nodes = self.nodes or {}
   self.neigh = self.neigh or {}
   -- no need to call dneigh.init
end

function ospf:get_hwf(rid)
   return rid
end

function ospf:iterate_asa(rid, f)
   for i, v in ipairs(self.asa)
   do
      f(v)
   end
end

function ospf:iterate_asp(rid, f)
   for i, v in ipairs(self.asp)
   do
      f(v)
   end
   mst.d('iterating nodes')

   for i, t in ipairs(self.nodes)
   do
      mst.d('dumping pa', i)

      for j, asp in ipairs(t:get_local_asp_values())
      do
         mst.a(not asp._is_done)
         mst.a(asp.rid)
         mst.a(t.rid == asp.rid)
         f(asp)
      end
   end
end

function ospf:iterate_usp(rid, f)
   for i, v in ipairs(self.usp)
   do
      f(v)
   end
end

function ospf:iterate_if(rid, f)
   for i, v in ipairs(self.iif[rid] or {})
   do
      f(v)
   end
end

function ospf:iterate_rid(rid, f)
   for i, v in ipairs(self.ridr)
   do
      f(v)
   end
   for i, pa in ipairs(self.nodes)
   do
      f{rid=pa.rid}
   end
end

function check_sanity()
   -- make sure there's not multiple lap with same prefix
   local seen = {}
   for i, v in ipairs(pa.lap:values())
   do
      mst.a(not seen[v.prefix], 'duplicate prefix', v)
      seen[v.prefix] = true
   end
end

function find_pa_lap(pa, criteria)
   mst.d('find_pa_lap', pa, criteria)

   for i, v in ipairs(pa.lap:values())
   do
      if mst.table_contains(v, criteria)
      then
         mst.d(' found', v)
         return v
      end
   end
end

function find_lap(prefix)
   return find_pa_lap(pa, {ascii_prefix=prefix})
end

function timeout_laps(pa, f)
   local laps = pa.lap:values()
   local c = 0
   for i, lap in ipairs(laps)
   do
      if not f or f(lap)
      then
         lap.sm:Timeout()
         c = c + 1
      end
   end
   return c
end

describe("pa", function ()
            before_each(function ()
                     o = ospf:new{usp={{prefix='dead::/16', rid='rid1'},
                                       {prefix='dead:beef::/32', rid='rid2'},
                                       {prefix='cafe::/16', rid='rid3'}},

                                  -- in practise, 2 usp
                                  asp={{prefix='dead:bee0::/64', 
                                        iid=256,  
                                        rid='rid1'}},
                                  iif={myrid={{index=42,name='if1'},
                                              {index=43,name='if2'}}},
                                  ridr={{rid='rid1'},
                                        {rid='rid2'},
                                        {rid='rid3'},
                                  },
                                 }
                     -- connect the asp-equipped rid1 if + myrid if1
                     o:connect_neigh('myrid', 42, 'rid1', 256)
                     pa = _pa.pa:new{client=o, lap_class=dummy_lap,
                                     rid='myrid'}
                  end)
            after_each(function ()
                        -- make sure pa seems sane
                        check_sanity()
                        -- and kill it explicitly
                        pa:done()
                        mst.a(timeouts:is_empty(), timeouts)
                     end)
            it("can be created", function ()
                                 end)
            it("works [small rid] #srid", function ()
                  pa:run()

                  -- make sure there's certain # of assignments
                  -- 2 USP, 2 if => 2 local assignments + 1 remote
                  -- (one not supplied by rid1, and it has higher rid on link)
                  mst.a(pa.lap:count() == 3, "lap mismatch", 4, pa.lap:count())
                  -- 1 original ASP + 2 from us => 3
                  mst.a(pa.asp:count() == 3, "asp mismatch")
                  -- 3 USP
                  mst.a(pa.usp:count() == 3, "usp mismatch")

                  pa:run()

                  mst.d('lap', pa.lap)


                  -- second run shouldn't change anything
                  mst.a(pa.lap:count() == 3, "lap mismatch")
                  mst.a(pa.asp:count() == 3, "asp mismatch")
                  mst.a(pa.usp:count() == 3, "usp mismatch")

                  -- make sure that if we get rid of usp+asp (from net),
                  -- local asp disappear, but lap won't
                  o.usp = {}
                  o.asp = {}
                  pa:run()
                  mst.a(pa.lap:count() == 3, "lap mismatch")
                  mst.a(pa.asp:count() == 0, "asp mismatch")
                  mst.a(pa.usp:count() == 0, "usp mismatch")

                  -- do fake timeout calls => go to zombie mode
                  timeout_laps(pa)

                  -- second timeout should do zombie -> done
                  timeout_laps(pa, function (lap)
                                  local sn = lap.sm:getState().name
                                  mst.a(sn == 'LAP.Zombie', sn)
                                  return true
                                   end)

                  mst.a(pa.lap:count() == 0, "lap mismatch")
                  
                                    end)
            it("survives prefix exhaustion #many", function ()
                  --require 'profiler'
                  --profiler.start()

                  -- /56 usp, 300 interfaces -> should get 256 LAP/ASP
                  o.usp={{prefix='abcd:dead:beef:cafe::/56', rid='rid1'}}
                  o.asp = {}
                  local t = mst.array:new()
                  for i=1,300
                  do
                     -- {index=42, name='if1'}
                     t:insert({index=i, name=string.format('if%d', i)})
                  end
                  o.iif={myrid=t}
                  
                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.lap:count() == 256, "lap mismatch")
                  mst.a(pa.asp:count() == 256, "asp mismatch")

                  --profiler.stop()
                   end)
            
            it("make sure old assignments show up by default #old", function ()
                  o = ospf:new{usp={{prefix='dead::/16', rid='rid1'},
                                    {prefix='dead:beef::/32', rid='rid2'},
                                    {prefix='cafe::/16', rid='rid3'}},
                               -- in practise, 2 usp
                               asp={{prefix='dead:bee0::/64', 
                                     iid=30,
                                     rid='rid1'}},
                               iif={myrid={{index=42,name='if1'},
                                           {index=43,name='if2'}}},
                               ridr={{rid='rid1'},
                                     {rid='rid2'},
                                     {rid='rid3'},
                               },
                               neigh={myrid={[42]={rid1=30}}},
                              }
                  o:connect_neigh('myrid', 42, 'rid1', 30)
                  pa = _pa.pa:new{client=o, 
                                  rid='myrid',
                                  lap_class=dummy_lap,
                                  old_assignments={['dead::/16']=
                                                   {{43, 'dead:bee1::/64'},
                                                   },
                                  }}
                  pa:run()
                  mst.a(find_lap('dead:bee1::/64'))
                  pa:done()
                                                               end)

                   end)

describe("pa-nobody-else", function ()

            before_each(function ()
                     o = ospf:new{usp={},
                                  asp={},
                                  iif={myrid={{index=42,name='if1'},
                                              {index=43,name='if2'}}},
                                  ridr={{rid='myrid'}},
                                 }
                     pa = _pa.pa:new{client=o, lap_class=dummy_lap,
                                     rid='myrid'}

                        end)
            it("changes prefix if there is sudden conflict #conflict", function ()
                  o.usp = {{prefix='dead::/16', rid='rid1'}}
                  o.ridr = {{rid='myrid'}, {rid='rid1'},}
                  pa:run()
                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.asp:count() == 2, "asp mismatch", pa.asp)
                  mst.a(pa.lap:count() == 2, "lap mismatch", pa.lap)

                  -- ok, now we grab one prefix and pretend it's
                  -- assigned elsewhere too (cruel but oh well)
                  local first_lap = pa.lap:values()[1]
                  table.insert(o.asp, {prefix=first_lap.prefix, 
                                       iid=44, rid='rid1'})
                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.asp:count() == 2, "asp mismatch", pa.asp)
                  -- should have one depracated one
                  mst.a(pa.lap:count() == 2, "lap mismatch", pa.lap)

                  -- due how to alg is specified in arkko-02, there's
                  -- one tick after which there is no assignment on
                  -- the interface, but next tick new one's created

                  -- should have new ASP to replace old one 
                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.asp:count() == 3, "asp mismatch", pa.asp)
                  mst.a(pa.lap:count() == 3, "lap mismatch", pa.lap)

                   end)


            it("obeys hysteresis 1 - no routers", function ()
                  -- just local e.g. PD prefix
                  o.usp = {{prefix='dead::/16', rid='myrid'}}
                  pa.new_prefix_assignment = 123
                  pa:run()
                  -- should have v4 USP, but not yet ASP due to ASP delay
                  mst.a(pa.usp:count() == 2, "usp mismatch", pa.usp)
                  mst.a(pa.asp:count() == 0, "asp mismatch", pa.asp)
                  mst.a(pa.lap:count() == 0, "lap mismatch", pa.lap)
                                                  end)
            it("obeys hysteresis 2 - time long gone", function ()
                  -- just local e.g. PD prefix
                  o.usp = {{prefix='dead::/16', rid='myrid'}}
                  pa.new_prefix_assignment = 123
                  pa.start_time = pa.start_time - pa.new_prefix_assignment - 10
                  pa:run()
                  mst.a(pa.lap:count() > 0, "lap mismatch", pa.lap)
                  mst.a(pa.asp:count() > 0, "asp mismatch", pa.asp)
                  -- should have v4 prefix now too (but no ULA)
                  mst.a(pa.usp:count() == 2, "usp mismatch", pa.usp)
                                                  end)
            it("obeys hysteresis 3 - other rid present", function ()
                  -- just local e.g. PD prefix
                  o.usp = {{prefix='dead::/16', rid='myrid'}}
                  o.ridr = {{rid='myrid'}, {rid='rid1'},}
                  pa.new_prefix_assignment = 123
                  pa.start_time = pa.start_time - pa.new_prefix_assignment - 10
                  pa:run()
                  mst.a(pa.lap:count() > 0, "lap mismatch")
                  mst.a(pa.asp:count() > 0, "asp mismatch")
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                                                  end)

            it("ula generation 1 - higher rid exists", function ()
                  o.ridr = {{rid='myrid'}, {rid='rid1'},}
                  pa:run()
                  mst.a(pa.lap:count() == 0, "lap mismatch")
                  mst.a(pa.asp:count() == 0, "asp mismatch")
                  mst.a(pa.usp:count() == 0, "usp mismatch")
                   end)

            it("ula generation works - time long gone #ula", function ()
                  -- disable the v4 on first interface => should have just 1
                  -- v4 ASP + LAP
                  o.iif.myrid[1].disable_v4 = 1

                  pa:run()
                  pa.new_ula_prefix = 123
                  pa.start_time = pa.start_time - pa.new_ula_prefix - 10
                  -- ula + IPv4
                  mst.a(pa.usp:count() == 2, "usp mismatch")
                  mst.a(pa.asp:count() == 3, "asp mismatch")
                  mst.a(pa.lap:count() == 3, "lap mismatch")
                  pa:run()

                  -- ula + IPv4
                  mst.a(pa.usp:count() == 2, "usp mismatch")
                  mst.a(pa.asp:count() == 3, "asp mismatch")
                  mst.a(pa.lap:count() == 3, "lap mismatch")

                  -- however, if we add real USP, the ULA should disappear
                  -- (and v4 too, as other one has higher rid)
                  table.insert(o.usp, {prefix='dead::/16', rid='rid1'})
                  o.ridr = {{rid='myrid'}, {rid='rid1'},}
                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.asp:count() == 2, "asp mismatch")
                  mst.a(pa.lap:count() == 5, "lap mismatch")

                  -- initially they will go unassigned once ULA is gone
                  local c = timeout_laps(pa, function (lap)
                                            return lap.assigned==false
                                             end)
                  mst.a(c == 3, c)

                  -- then depracate
                  local c = timeout_laps(pa, function (lap)
                                            return lap.depracated==true
                                             end)
                  mst.a(c == 3, c)
                   

                  pa:run()
                  mst.a(pa.usp:count() == 1, "usp mismatch")
                  mst.a(pa.asp:count() == 2, "asp mismatch", pa.asp)
                  mst.a(pa.lap:count() == 2, "lap mismatch", pa.lap)


                   end)

            after_each(function ()
                        -- make sure pa seems sane
                        check_sanity()
                        -- and kill it explicitly
                        pa:done()
                        mst.a(timeouts:is_empty(), timeouts)
                       end)
             end)

describe("pa-net", function ()
            it("simple 3 pa #net", function ()


                  -- few different variants
                  -- bit1 = connect the routers after awhile
                  -- bit2 = connect the LSAdbs after awhile
                  -- bit3 = use conflicting if #'s

                  -- bit1 implies bit2 as well

                  for j=0,7
                  do
                     mst.d('net-iter', j)
                     
                     local _n
                     if mst.bitv_is_set_bit(j, 3)
                     then
                        function _n(ni, pi)
                           return 40 + pi
                        end
                     else
                        function _n(ni, pi)
                           return 30 + pi + ni * 10
                        end
                     end

                     local connect_lsadbs_slowly = false
                     local connect_routers_slowly = false

                     if mst.bitv_is_set_bit(j, 2)
                     then
                        connect_lsadbs_slowly = true
                     end

                     if mst.bitv_is_set_bit(j, 1)
                     then
                        connect_routers_slowly = true
                     end

                     if connect_routers_slowly
                     then
                        connect_lsadbs_slowly = true
                     end

                     -- XXX - add same/different ifindex variants
                     -- to bit 2
                     o = ospf:new{usp={{prefix='dead::/16', rid='rid1'},
                                      },
                                  iif={n1={{index=_n(1, 2),name='if1'}, 
                                           {index=_n(1, 3),name='if2'}, 
                                           {index=_n(1, 1),name='if0'}},
                                       n2={{index=_n(2, 3),name='if2'}, 
                                           {index=_n(2, 4),name='if3'}, 
                                           {index=_n(2, 1),name='if0'}},
                                       n3={{index=_n(3, 4),name='if3'}, 
                                           {index=_n(3, 5),name='if4'}, 
                                           {index=_n(3, 1),name='if0'}},
                                  },
                                  ridr={{rid='rid1'},
                                        {rid='rid2'},
                                        {rid='rid3'},
                                  },
                                 }
                     local neighs = o.neigh

                     -- individual toy nets 
                     o:connect_neigh('n1', _n(1, 3), 'n2', _n(2, 3))
                     o:connect_neigh('n2', _n(2, 4), 'n3', _n(3, 4))

                     -- nets 2, 5 have zero connectivity (2 == n1, 5 == n3)

                     -- mgmt net - connect all
                     o:connect_neigh('n1', _n(1, 1), 'n2', _n(2, 1))
                     o:connect_neigh('n1', _n(1, 1), 'n3', _n(3, 1))
                     o:connect_neigh('n2', _n(2, 1), 'n3', _n(3, 1))
                     

                     mst.d('simple 3 pa iter', j)

                     local n1 = _pa.pa:new{client=o, 
                                           rid='n1',
                                           lap_class=dummy_lap,
                                          }
                     local n2 = _pa.pa:new{client=o, 
                                           rid='n2',
                                           lap_class=dummy_lap,
                                          }
                     local n3 = _pa.pa:new{client=o, 
                                           rid='n3',
                                           lap_class=dummy_lap,
                                          }
                     local nl = mst.array:new{n1, n2, n3}

                     if connect_routers_slowly
                     then
                        o.neigh = {}
                     end

                     if not connect_lsadbs_slowly
                     then
                        -- connect the pa's
                        o.nodes = nl
                     end

                     for i=1,2
                     do
                        mst.d('run1 iter', i)
                        for i, n in ipairs(nl)
                        do
                           n:run()
                        end
                     end

                     if connect_routers_slowly
                     then
                        o.neigh = neighs
                     end


                     if connect_lsadbs_slowly
                     then
                        -- connect the pa's
                        o.nodes = nl
                     end

                     for i=1,5
                     do
                        mst.d('run2 iter', i)
                        for i, n in ipairs(nl)
                        do
                           n:run()
                        end
                     end

                     -- make sure there's local assignments
                     mst.a(find_pa_lap(n1, {iid=_n(1, 2)}))
                     mst.a(find_pa_lap(n1, {iid=_n(1, 3)}))
                     mst.a(not find_pa_lap(n1, {iid=_n(1, 4)}))

                     mst.a(not find_pa_lap(n2, {iid=_n(2, 2)}))
                     mst.a(find_pa_lap(n2, {iid=_n(2, 3)}))
                     mst.a(find_pa_lap(n2, {iid=_n(2, 4)}))

                     mst.a(not find_pa_lap(n3, {iid=_n(3, 2)}))
                     mst.a(not find_pa_lap(n3, {iid=_n(3, 3)}))
                     mst.a(find_pa_lap(n3, {iid=_n(3, 4)}))
                     mst.a(find_pa_lap(n3, {iid=_n(3, 5)}))

                     -- make sure mgmt if is everywhere
                     mst.a(find_pa_lap(n1, {iid=_n(1, 1)}))
                     mst.a(find_pa_lap(n2, {iid=_n(2, 1)}))
                     mst.a(find_pa_lap(n3, {iid=_n(3, 1)}))

                     local ls = mst.array_map(nl, 
                                              function (n)
                                                 return n:get_local_asp_values()
                                              end)

                     -- each should have one local asp, except
                     -- the n3 has if0 + if3
                     mst.a(#ls == 3, #ls)
                     mst.d('got', ls[1])

                     mst.d('got', #ls[1], #ls[2], #ls[3])

                     -- regardless of the configuration, 
                     -- due to how rules work, the n3 should have overriding
                     -- preference
                     mst.a(#ls[1] == 1)
                     mst.a(#ls[2] == 1)
                     mst.a(#ls[3] == 3)

                     -- finally clear up things
                     for i, v in ipairs(nl)
                     do
                        v:done()
                     end

                  end

                              end)
                   end)
