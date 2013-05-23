#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_test.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May 23 20:37:09 2013 mstenber
-- Last modified: Thu May 23 20:54:13 2013 mstenber
-- Edit time:     1 min
--

-- testing related utilities

module(..., package.seeall)

-- run test list given in a, giving first item as argument to the f,
-- and making sure second item is assert_equsl to the first.
function test_list(a, f, assert_equals)
   for i, v in ipairs(a)
   do
      mst.d('test_list', i)
      local input, output = unpack(v)

      -- then call test function
      local result, err = f(input)

      -- and make sure that (repr-wise) result is correct
      assert_equals = assert_equals or function (v1, v2)
         mst.a(mst.repr_equal(v1, v2), 
               'not same - exp', v1, 
               'got', v2,
               'for',
               input)
                                       end
      assert_equals(output, result)
   end
end

fake_callback = mst.create_class{class='fake_callback'}

function fake_callback:init()
   self.array = self.array or mst.array:new{}
   self.i = self.i or 0
end

function fake_callback:repr_data()
   return mst.repr{i=self.i,n=#self.array,name=self.name}
end

function fake_callback:__call(...)
   self:a(self.i < #self.array, 'not enough left to serve', {...})
   self.i = self.i + 1
   local got = {...}
   local exp, r = unpack(self.array[self.i])
   self.assert_equals(exp, got)
   return r
end

function fake_callback.assert_equals(exp, got)
   mst.a(mst.repr_equal(exp, got), 
         'non-expected input - exp/got', exp, got)
end

function fake_callback:uninit()
   self:a(self.i == #self.array, 'wrong amount consumed', self.i, #self.array, self.array)
end

