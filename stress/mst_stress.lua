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
-- Last modified: Wed Feb  6 14:20:48 2013 mstenber
-- Edit time:     9 min
--


require 'busted'
require 'mst'
require "mst_skiplist"
require "dint"

local ipi_skiplist = mst_skiplist.ipi_skiplist
local dummy_int = dint.dint

local NUMBER_OF_VALUES=100
local DUP_FACTOR=10
local NUMBER_OF_ITEMS=NUMBER_OF_VALUES * DUP_FACTOR
local SANITY_EVERY=10

describe("ipi_skiplist", function ()
            local function test_sim(enable_width)
               -- basic idea: we have 100 fake objects;
               -- we have two arrays ('in', 'out') and 
               -- ipilist, where we put stuff from 'out',
               -- and remove items from 'in' every cycle.
               -- we repeat this for X cycles, and
               -- hopefully cover most cases this way
               -- (it's not very scientific method, unfortunately)
               local width
               if not enable_width
               then
                  width = false
               end
               local obj_in = mst.array:new{}
               local obj_out = mst.array:new{}
               local sl = ipi_skiplist:new{p=2, width=width}
               for i=1,NUMBER_OF_VALUES
               do
                  for j=1,DUP_FACTOR
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
                        local o = mst.array_randitem(obj_in)
                        if o
                        then
                           mst.a(sl:get_first())
                           obj_in:remove(o)
                           obj_out:insert(o)
                           sl:remove(o)
                        else
                           mst.a(#obj_in == 0)
                        end
                     else
                        -- add 
                        local o = mst.array_randitem(obj_out)
                        if o
                        then
                           obj_out:remove(o)
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
               sim(50, NUMBER_OF_ITEMS * 10)

               -- then ramp up to full, first with 90%
               sim(90, NUMBER_OF_ITEMS * 2)

               -- and then last bit with 100% add chance
               sim(100, NUMBER_OF_ITEMS / 10)
               mst.a(#obj_out == 0)
               mst.a(#obj_in == NUMBER_OF_ITEMS, #obj_in)

               -- then simulate lots of iterations ~full
               sim(50, NUMBER_OF_ITEMS * 10)

               -- and then ramp to down, with 10% chance of add
               sim(10, NUMBER_OF_ITEMS * 2)

               -- and last bit certain removes
               sim(0, NUMBER_OF_ITEMS / 10)
               mst.a(#obj_in == 0)
               mst.a(#obj_out == NUMBER_OF_ITEMS, #obj_out)
            end

            it("simulated long run #lr", function ()
                  test_sim(false)
                                         end)

            it("simulated long run with width #lrw", function ()
                  test_sim(true)
                                                     end)
                         end)

