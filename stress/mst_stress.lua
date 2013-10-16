#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_stress.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Feb  4 16:24:43 2013 mstenber
-- Last modified: Wed Oct 16 14:32:02 2013 mstenber
-- Edit time:     41 min
--


require 'mst'
require "mst_skiplist"
require "mst_test"
require "dint"

local ipi_skiplist = mst_skiplist.ipi_skiplist
local dummy_int = dint.dint

--local SANITY_EVERY=10
local SANITY_EVERY=123456789

local NUMBER_OF_VALUES=10000
local DUP_FACTOR=10
local NUMBER_OF_ITEMS=NUMBER_OF_VALUES * DUP_FACTOR

skiplist_sim = mst.create_class{class='skiplist_sim',
                                skiplist_p=2,
                                skiplist_width=false,
                                number_of_values=1000,
                                dup_factor=10,
                               }

function skiplist_sim:run()
   -- basic idea: we have X fake objects;
   -- we have two arrays ('in', 'out') and 
   -- ipilist, where we put stuff from 'out',
   -- and remove items from 'in' every cycle.
   -- we repeat this for X cycles, and
   -- hopefully cover most cases this way
   -- (it's not very scientific method, unfortunately)
   local obj_in = mst.array:new{}
   local obj_out = mst.array:new{}
   local sl = ipi_skiplist:new{p=self.skiplist_p, width=self.skiplist_width}
   self.number_of_items = self.number_of_values * self.dup_factor
   for i=1,self.number_of_values
   do
      for j=1,self.dup_factor
      do
         obj_out:insert(dummy_int:new{v=i})
      end
   end
   local function sim(chance_insert, ic)
      for i=1,ic
      do
         if mst.randint(1, 100) > chance_insert
         then
            -- remove
            local o, i = mst.array_randitem(obj_in)
            if o
            then
               mst.d('performing remove', o)
               mst.a(sl:get_first())
               obj_in:remove_index(i)
               obj_out:insert(o)
               sl:remove(o)
            else
               mst.a(#obj_in == 0)
            end
         else
            -- add 
            local o, i = mst.array_randitem(obj_out)
            if o
            then
               mst.d('performing add', o)
               obj_out:remove_index(i)
               obj_in:insert(o)
               sl:insert(o)
               mst.a(sl:get_first())
            else
               mst.a(#obj_out == 0)
            end
         end
         if i % SANITY_EVERY == 0
         then
            sl:sanity_check()
         end
      end
   end
   -- first, lots of iterations ~empty
   sim(50, self.number_of_items * 10)

   -- then ramp up to full, first with 90%
   sim(90, self.number_of_items * 2)

   -- and then last bit with 100% add chance
   sim(100, self.number_of_items / 10)
   mst.a(#obj_out == 0)
   mst.a(#obj_in == self.number_of_items, #obj_in)

   -- then simulate lots of iterations ~full
   mst_test.perf_test:new{cb=function ()
                             sim(50, 1)
   end,
                          duration=0.2,
                          name='ipi_skiplist:' .. mst.repr{self},
                         }:run()

   --sim(50, self.number_of_items * 10)

   -- and then ramp to down, with 10% chance of add
   sim(10, self.number_of_items * 2)

   -- and last bit certain removes
   sim(0, self.number_of_items / 10)
   mst.a(#obj_in == 0)
   mst.a(#obj_out == self.number_of_items, #obj_out)
end


local pmat = {2, 3, 4, 5, 6, 7, 8, 16}

for i, v in ipairs(pmat)
do
   skiplist_sim:new{number_of_values=1000, skiplist_p=v}:run()
end

local mat = {10, 100, 1000}

for i, v in ipairs(mat)
do
   skiplist_sim:new{number_of_values=v}:run()
   skiplist_sim:new{number_of_values=v, skiplist_width=true}:run()
   skiplist_sim:new{number_of_values=v, skiplist_p=4}:run()
end
