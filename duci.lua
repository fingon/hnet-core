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
-- Last modified: Mon Oct  7 17:35:06 2013 mstenber
-- Edit time:     6 min
--

-- Mock for testing UCI APIs (very limited, just for our own use).

require 'mst'
require 'mst_test'

module(..., package.seeall)

local _parent = mst_test.fake_object

duci = _parent:new_subclass{class='duci',
                            fake_methods={'set', 'commit'}}

function duci:init()
   _parent.init(self)
   self.foreach_data = mst_test.fake_callback:new{name='foreach_data'}
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
   _parent.uninit(self)
   self.foreach_data:done()
end
