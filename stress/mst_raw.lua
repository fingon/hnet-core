#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_raw.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Feb  4 16:24:43 2013 mstenber
-- Last modified: Wed Oct 16 16:28:14 2013 mstenber
-- Edit time:     52 min
--


require 'mst'
require "mst_skiplist"
require "mst_test"
require "dint"

local ipi_skiplist = mst_skiplist.ipi_skiplist
local dummy_int = dint.dint

local ptest = mst_test.perf_test:new_subclass{duration=1}

local nop = ptest:new{cb=function ()
                         -- nop
                         end,
                      name='nop',
                     }

local rnd100 = ptest:new{cb=function ()
                         mst.randint(1, 100)
                         end,
                      name='randint(1,100)',
                      overhead={nop},
                     }


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
   local obj_in = mst.iset:new{}
   local obj_out = mst.iset:new{}
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
            local o = obj_in:randitem()
            if o
            then
               mst.d('performing remove', o)
               obj_in:remove(o)
               obj_out:insert(o)
               sl:remove(o)
            else
               mst.a(#obj_in == 0)
            end
         else
            -- add 
            local o = obj_out:randitem()
            if o
            then
               mst.d('performing add', o)
               obj_out:remove(o)
               obj_in:insert(o)
               sl:insert(o)
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
   mst_test.assert_repr_equal(obj_out:count(), 0)
   mst_test.assert_repr_equal(obj_in:count(), self.number_of_items)

   local rnditem = ptest:new{cb=function ()
                                obj_in:randitem()
                                end,
                             name='randitem',
                             overhead={nop},
                            }

   -- then simulate lots of iterations ~full
   mst_test.perf_test:new{cb=function ()
                             sim(50, 1)
   end,
                          duration=0.2,
                          name=mst.repr{self},
                          -- there's two random calls there;
                          -- whether or not that really matters is questionable
                          overhead={nop, rnd100, rnditem},
                         }:run()

   --sim(50, self.number_of_items * 10)

   -- and then ramp to down, with 10% chance of add
   sim(10, self.number_of_items * 2)

   -- and last bit certain removes
   sim(0, self.number_of_items / 10)
   mst_test.assert_repr_equal(obj_in:count(), 0)
   mst_test.assert_repr_equal(obj_out:count(), self.number_of_items)
end


--local pmat = {2, 3, 4, 5, 6, 7, 8, 16}
local pmat = {2, 7}

for i, v in ipairs(pmat)
do
   skiplist_sim:new{number_of_values=1000, skiplist_p=v}:run()
end

--local mat = {10, 100, 1000}
local mat = {10, 100, 1000}

for i, v in ipairs(mat)
do
   skiplist_sim:new{number_of_values=v}:run()
   --skiplist_sim:new{number_of_values=v, skiplist_width=true}:run()
end
