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
-- Last modified: Mon Feb  4 16:28:05 2013 mstenber
-- Edit time:     2 min
--


require 'busted'
require 'mst'
require "mst_skiplist"
require "dint"

local ipi_skiplist = mst_skiplist.ipi_skiplist
local dummy_int = dint.dint

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
               for i=1,100
               do
                  obj_out:insert(dummy_int:new{v=i})
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
                        end
                     end
                  end
               end
               sim(50, 1000)
               sim(90, 200)
               sim(100, 10)
               mst.a(#obj_out == 0)
               sim(10, 200)
               sim(0, 10)
               mst.a(#obj_out == 100, #obj_out)
            end

            it("simulated long run #lr", function ()
                  test_sim(false)
                                         end)

            it("simulated long run with width #lrw", function ()
                  test_sim(true)
                                                     end)
                         end)

