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
-- Last modified: Tue Oct  2 13:49:05 2012 mstenber
-- Edit time:     30 min
--

require "busted"
local _pa = require "pa"
require 'mst'


-- 3 globals used to keep track of stuff
ospf = nil
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

dummy_ospf = mst.create_class{class='dummy_ospf',
                              asp = {},
                              usp = {},
                              iif = {},
                              ridr = {},
                              rid = 'myrid',
}

function dummy_ospf:iterate_asp(f)
   for i, v in ipairs(self.asp)
   do
      f(unpack(v))
   end
end

function dummy_ospf:iterate_usp(f)
   for i, v in ipairs(self.usp)
   do
      f(unpack(v))
   end
end

function dummy_ospf:iterate_if(f)
   for i, v in ipairs(self.iif)
   do
      f(unpack(v))
   end
end

function dummy_ospf:iterate_rid(f)
   for i, v in ipairs(self.ridr)
   do
      f(unpack(v))
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

describe("pa", function ()
            setup(function ()
                  ospf = dummy_ospf:new{usp={{'dead::/16', 'rid1'},
                                             {'dead:beef::/32', 'rid2'},
                                             {'cafe::/16', 'rid3'}},

                                              -- in practise, 2 usp
                                              asp={{'dead:bee0::/64', 
                                                    'if1',
                                                    'rid1'}},
                                              iif={{'if1'},
                                                   {'if2'}},
                                              ridr={{'rid1'},
                                                    {'rid2'},
                                                    {'rid3'},
                                              },
                                             }
                  pa = _pa.pa:new{client=ospf, lap_class=dummy_lap}
                  end)
            teardown(function ()
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

