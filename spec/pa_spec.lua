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
-- Last modified: Mon Oct  1 17:03:09 2012 mstenber
-- Edit time:     13 min
--

require "luacov"
require "busted"
require "pa"
require 'mst'

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


describe("pa", function ()
            it("can be created", function ()
                  local pa = pa.pa:new()
                                 end)
            it("can do nop run or two", function ()
                  local ospf = dummy_ospf:new()
                  local pa = pa.pa:new{client=ospf}
                  pa:run()
                  pa:run()
                                 end)
            it("works1", function ()
                  local ospf = dummy_ospf:new{usp={{'dead::/16', 'rid1'},
                                                   {'dead:beef::/32', 'rid2'},
                                                   {'cafe::/16', 'rid3'}},
                                              asp={{'dead:bee0::/64', 'if0', 'rid1'}},
                                              iif={{'if1'},
                                                   {'if2'}},
                                              ridr={{'rid1'},
                                                    {'rid2'},
                                                    {'rid3'},
                                              },
                                             }
                  local pa = pa.pa:new{client=ospf}
                  pa:run()
                  pa:run()
                                 end)
            
               end)

