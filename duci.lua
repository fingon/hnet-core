#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: duci.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Oct  7 13:49:27 2013 mstenber
-- Last modified: Mon Oct  7 14:20:00 2013 mstenber
-- Edit time:     4 min
--

-- Mock for testing UCI APIs (very limited, just for our own use).

require 'mst'
require 'mst_test'

module(..., package.seeall)

duci = mst.create_class{class='duci'}

function duci:init()
   self.set = mst_test.fake_callback:new{skip=1}
   self.commit = mst_test.fake_callback:new{skip=1}
   self.foreach_data = mst_test.fake_callback:new()
end

function duci:foreach(c, t, fun)
   local l = self.foreach_data(c, t)
   for i, v in ipairs(l)
   do
      local r = fun(v)
      if r == false
      then
         return
      end
   end
end

function duci:uninit()
   self.set:done()
   self.commit:done()
   self.foreach_data:done()
end
