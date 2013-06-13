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
-- Last modified: Thu Jun 13 12:51:58 2013 mstenber
-- Edit time:     10 min
--

-- testing related utilities
require 'mst'
require 'ssloop'

module(..., package.seeall)

-- first some individual functions

-- convenience function to make sure that o1 == o2 (as far as repr
-- goes)
function assert_repr_equal(o1, o2, ...)
   -- equality is trivially repr_equal too
   if o1 == o2
   then
      return
   end
   local r1 = mst.repr(o1)
   local r2 = mst.repr(o2)
   mst.a(r1 == r2, 
         'assert_repr_equal failure got', r1, 'expected', r2, ...)
end


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
      local assert_equals = assert_equals or function (v1, v2)
         assert_repr_equal(v2, v1, 'for', input)
                                       end
      assert_equals(output, result)
   end
end

-- create iterator and a list; the calls to iterator are stored in the list
function create_storing_iterator_and_list()
   local t = {}
   local f = function (...)
      table.insert(t, {...})
   end
   return f, t
end

function inject_snitch(o, n, sf)
   local f = o[n]
   o[n] = function (...)
      sf(...)
      return f(...)
   end
end

function inject_refcounted_terminator(o, n, c)
   local l = ssloop.loop()
   local terminator = function ()
      c[1] = c[1] - 1
      if c[1] == 0
      then
         l:unloop()
      end
   end
   inject_snitch(o, n, terminator)
end

function add_eventloop_terminator(o, n)
   local c = {1}
   inject_refcounted_terminator(o, n, c)
end


-- fake callback class for fun and profit

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

