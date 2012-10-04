#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pa_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  1 11:49:11 2012 mstenber
-- Last modified: Thu Oct  4 13:00:21 2012 mstenber
-- Edit time:     116 min
--

require "busted"
local _pa = require "pa"
require 'mst'


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

ospf = mst.create_class{class='ospf'}

function ospf:init()
   self.asp = self.asp or {}
   self.usp = self.usp or {}
   self.iif = self.iif or {}
   self.ridr = self.ridr or {}
   self.pas = self.pas or {}
end

function ospf:iterate_asp(rid, f)
   for i, v in ipairs(self.asp)
   do
      f(unpack(v))
   end
   mst.d('iterating pas')

   for i, t in ipairs(self.pas)
   do
      mst.d('dumping pa', i)

      for j, asp in ipairs(t:get_local_asp_values())
      do
         mst.a(not asp._is_done)
         mst.a(asp.rid)
         mst.a(t.rid == asp.rid)
         f(asp.prefix, asp.iid, asp.rid)
      end
   end
end

function ospf:iterate_usp(rid, f)
   for i, v in ipairs(self.usp)
   do
      f(unpack(v))
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
      f(unpack(v))
   end
   for i, pa in ipairs(self.pas)
   do
      f(pa.rid)
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
      if not criteria.prefix or criteria.prefix == v.prefix
      then
         if not criteria.iid or criteria.iid == v.iid
         then
            mst.d(' found', v)
            return v
         end
      end
   end
end

function find_lap(prefix)
   return find_pa_lap(pa, {prefix=prefix})
end

describe("pa", function ()
            before_each(function ()
                     o = ospf:new{usp={{'dead::/16', 'rid1'},
                                       {'dead:beef::/32', 'rid2'},
                                       {'cafe::/16', 'rid3'}},

                                  -- in practise, 2 usp
                                  asp={{'dead:bee0::/64', 
                                        42, -- #if1
                                        'rid1'}},
                                  iif={myrid={{index=42,name='if1'},
                                              {index=43,name='if2'}}},
                                  ridr={{'rid1'},
                                        {'rid2'},
                                        {'rid3'},
                                  },
                                 }
                     pa = _pa.pa:new{client=o, lap_class=dummy_lap,
                                     rid='myrid'}
                  end)
            after_each(function ()
                        -- make sure pa seems sane
                        check_sanity()
                        -- and kill it explicitly
                        pa:done()
                        mst.a(timeouts:is_empty())
                     end)
            it("can be created", function ()
                                 end)
            it("works [small rid]", function ()
                  pa:run()

                  -- make sure there's certain # of assignments
                  -- 2 USP, 2 if => 3 local assignments + 1 remote
                  mst.a(pa.lap:count() == 4, "lap mismatch")
                  -- 1 original ASP + 3 from us => 4
                  mst.a(pa.asp:count() == 4, "asp mismatch")
                  -- 3 USP
                  mst.a(pa.usp:count() == 3, "usp mismatch")

                  pa:run()

                  mst.d('lap', pa.lap)


                  -- second run shouldn't change anything

                  -- make sure there's certain # of assignments
                  -- 2 USP, 2 if => 3 local assignments + 1 remote
                  mst.a(pa.lap:count() == 4, "lap mismatch")
                  -- 1 original ASP + 3 from us => 4
                  mst.a(pa.asp:count() == 4, "asp mismatch")
                  -- 3 USP
                  mst.a(pa.usp:count() == 3, "usp mismatch")

                                    end)
            
               end)


describe("pa-old", function ()
            it("make sure old assignments show up by default", function ()
                  o = ospf:new{usp={{'dead::/16', 'rid1'},
                                    {'dead:beef::/32', 'rid2'},
                                    {'cafe::/16', 'rid3'}},
                               -- in practise, 2 usp
                               asp={{'dead:bee0::/64', 
                                     'if1',
                                     'rid1'}},
                               iif={myrid={{index=42,name='if1'},
                                           {index=43,name='if2'}}},
                               ridr={{'rid1'},
                                     {'rid2'},
                                     {'rid3'},
                               },
                              }
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

describe("pa-net", function ()
            it("simple 3 pa", function ()

                  -- two different variants of the same test case 3
                  -- routers, but they are connected to each other
                  -- either at the start (j=1), or after they've been
                  -- running a bit (j=2)

                  for j=1,2
                  do
                     o = ospf:new{usp={{'dead::/16', 'rid1'},
                                       --{'cafe::/16', 'rid3'},
                                      },
                                  iif={n1={{index=42,name='if1'}, 
                                           {index=43,name='if2'}, 
                                           {index=41,name='if0'}},
                                       n2={{index=43,name='if2'}, 
                                           {index=44,name='if3'}, 
                                           {index=41,name='if0'}},
                                       n3={{index=44,name='if3'}, 
                                           {index=45,name='if4'}, 
                                           {index=41,name='if0'}},
                                  },
                                  ridr={{'rid1'},
                                        {'rid2'},
                                        {'rid3'},
                                  },
                                 }
                     

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

                     if j == 1
                     then
                        -- connect the pa's
                        o.pas = nl
                     end

                     for i=1,2
                     do
                        mst.d('run1 iter', i)
                        for i, n in ipairs(nl)
                        do
                           n:run()
                        end
                     end


                     if j == 2
                     then
                        -- connect the pa's
                        o.pas = nl
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
                     mst.a(find_pa_lap(n1, {iid=42}))
                     mst.a(find_pa_lap(n1, {iid=43}))
                     mst.a(not find_pa_lap(n1, {iid=44}))

                     mst.a(not find_pa_lap(n2, {iid=42}))
                     mst.a(find_pa_lap(n2, {iid=43}))
                     mst.a(find_pa_lap(n2, {iid=44}))

                     mst.a(not find_pa_lap(n3, {iid=42}))
                     mst.a(not find_pa_lap(n3, {iid=43}))
                     mst.a(find_pa_lap(n3, {iid=44}))
                     mst.a(find_pa_lap(n3, {iid=45}))

                     -- make sure mgmt if is everywhere
                     mst.a(find_pa_lap(n1, {iid=41}))
                     mst.a(find_pa_lap(n2, {iid=41}))
                     mst.a(find_pa_lap(n3, {iid=41}))

                     local ls = mst.array_map(nl, 
                                              function (n)
                                                 return n:get_local_asp_values()
                                              end)

                     -- each should have one local asp, except
                     -- the n3 has if0 + if3
                     mst.a(#ls == 3, #ls)
                     mst.d('got', ls[1])

                     mst.d('got', #ls[1], #ls[2], #ls[3])

                     if j == 1
                     then
                        mst.a(#ls[1] == 3)
                        mst.a(#ls[2] == 1)
                        mst.a(#ls[3] == 1)
                     else
                        mst.a(#ls[1] == 1)
                        mst.a(#ls[2] == 1)
                        mst.a(#ls[3] == 3)
                     end

                  -- finally clear up things
                  for i, v in ipairs(nl)
                  do
                     v:done()
                  end

                  end

                              end)
                   end)
