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
-- Last modified: Mon Oct 21 10:45:59 2013 mstenber
-- Edit time:     65 min
--

-- testing related utilities
require 'mst'
require 'ssloop'
require 'socket' -- for socket.gettime

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
         'assert_repr_equal failure \ngot:    ', r1, '\nexpected:', r2, ...)
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
   mst.a(o and n and sf, 'invalid arguments')
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

fake_callback = mst.create_class{class='fake_callback',
                                 unpack_r=false}

function fake_callback:init()
   self.array = self.array or mst.array:new{}
   self.i = self.i or 0
   self.skip = self.skip or 0
end

function fake_callback:set_array(array)
   self.i = 0
   self.array = array
end

function fake_callback:add_expected(args, return_value)
   args = args or {}
   self.array:insert{args, return_value}
end

function fake_callback:repr_data()
   return mst.repr{i=self.i,n=#self.array,name=self.name}
end

function fake_callback:__call(...)
   local got = {...}
   if self.skip > 0
   then
      got = mst.array_slice(got, self.skip + 1)
   end
   self:a(self.i < #self.array, 'not enough left to serve', got)
   self.i = self.i + 1
   local exp, r = unpack(self.array[self.i])
   self.assert_equals(exp, got)
   self:d('returning', r)
   if self.unpack_r
   then
      return self.unpack_r(r)
   end
   return r
end

function fake_callback.assert_equals(exp, got)
   mst.a(mst.repr_equal(exp, got), 
         'non-expected input - exp/got', exp, got)
end

function fake_callback:check_used()
   self:a(self.i == #self.array, 'wrong amount consumed', self.i, #self.array, self.array)
end

function fake_callback:uninit()
   self:check_used()
end


-- fake object which has specified fake callbacks
fake_object = mst.create_class{class='fake_object', mandatory={'fake_methods'}}

function fake_object:init()
   for i, v in ipairs(self.fake_methods)
   do
      self[v] = fake_callback:new{skip=1, name=v}
   end
end

function fake_object:uninit()
   for i, v in ipairs(self.fake_methods)
   do
      self[v]:done()
   end
end

function fake_object:check_used()
   for i, v in ipairs(self.fake_methods)
   do
      self[v]:check_used()
   end
end

-- minimalist performance testing functionality
-- assumption: one call is ~equal to another
perf_test = mst.create_class{class='perf_test',
                             mandatory={'cb'},
                             duration=1, -- how long can we test at most
                             verbose=false,
                            }

function perf_test:run()
   self:d('run()')

   -- two different modes; if self.count is specified, just do known
   -- number of runs.
   if self.count
   then
      local t1 = socket.gettime()
      for i=1, self.count
      do
         self.cb()
      end
      local t2 = socket.gettime()
      local got = {t2-t1, self.count}
      self:report_result(unpack(got))
      return
   end
   
   -- if not, use duration as guideline for how long to run

   -- basic idea: double # of tests every iteration show iterations
   -- that takes >= 10% of the budget (so the minimal, insanely fast
   -- ones in the beginning do not show)
   local now = socket.gettime()
   local strep = now + 0.1 * self.duration
   local done = now + self.duration / 2 -- next iteration would overflow
   local count = 1
   local r = mst.array:new{}
   while true
   do
      local t1 = socket.gettime()
      if t1 >= done
      then
         break
      end
      for i=1, count
      do
         self.cb()
      end
      local t2 = socket.gettime()
      if t2 >= strep
      then
         local got = {t2-t1, count}
         if self.verbose
         then
            self:report_result(unpack(got))
         else
            r:insert(got)
         end
      end
      count = count * 2
   end
   if not self.verbose
   then
      self:a(#r > 0)
      self:report_result(unpack(r[#r]))
   end
end

function perf_test:get_us_per_call()
   if not self.own_us_per_call
   then
      self:run()
   end
   return self.own_us_per_call
end

function perf_test:report_result(delta, count)
   self.us_per_call = 1000000.0 * delta / count
   if self.overhead
   then
      local overhead = 0
      for i, v in ipairs(self.overhead)
      do
         overhead = overhead + v:get_us_per_call()
      end
      self.own_us_per_call = self.us_per_call - overhead
      local n = (self.n or 1)
      self.own_us_per_call = self.own_us_per_call / n
      local nmul = n > 1 and string.format(" (x%d)", n) or ""
      print(string.format('%s: %.3f us (own%s), %.3f us (total)', self.name, self.own_us_per_call, nmul, self.us_per_call))
   else
      self.own_us_per_call = self.us_per_call
      local n = (self.n or 1)
      self.own_us_per_call = self.own_us_per_call / n
      local nmul = n > 1 and string.format(" (x%d)", n) or ""
      print(string.format('%s: %.3f us %s', self.name, self.us_per_call, nmul))
   end
   --print(self.name, 'cps', cps)
end
