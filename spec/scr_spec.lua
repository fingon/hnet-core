#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scr_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Apr 25 10:54:26 2013 mstenber
-- Last modified: Thu Apr 25 11:38:34 2013 mstenber
-- Edit time:     22 min
--

-- Simple testsuite for complex stuff - simple coroutine reactor tests

require "busted"
require "scr"

module("scr_spec", package.seeall)

-- lazyworker runs every N calls; return value is call + #calls object
function create_lazyworker(n)
   local ncalls = {0}
   local function x()
      local ccalls = 0
      local function y()
         ccalls = ccalls + 1
         return ccalls % n == 0
      end
      while true
      do
         -- we've been called
         ncalls[1] = ncalls[1] + 1
         coroutine.yield(y)
      end
   end
   return x, ncalls
end

local function always_true()
   return true
end

function create_storeworker()
   local args = {}
   local function x(...)
      table.insert(args, {...})
      while true
      do
         local y = always_true
         local r = {coroutine.yield(y, y, y)}
         table.insert(args, r)
      end
   end
   return x, args
end

function create_nopworker(nyields)
   local ncalls = {0}
   local function x()
      mst.d('nopworker starting')
      ncalls[1] = ncalls[1] + 1
      local c = nyields or 0
      for i=1,c
      do
         mst.d('nopworker yielding')
         coroutine.yield(always_true)
         ncalls[1] = ncalls[1] + 1
      end
      mst.d('nopworker done')

   end
   return x, ncalls
end

describe("scr", function ()
            it("works", function ()
                  local scr = scr.scr:new{}
                  local w, ncalls = create_lazyworker(3)

                  scr:run(w)
                  -- rtc completion => first call (+ first call to check)
                  scr:poll()
                  mst.a(ncalls[1] == 1, ncalls)
                  scr:poll()
                  mst.a(ncalls[1] == 1)
                  scr:poll()

                  mst.a(ncalls[1] == 2)

                   end)
            it("arguments passed as they should be #ar", function ()
                  local scr = scr.scr:new{}
                  local w, args = create_storeworker()
                  scr:run(w, 1, 2, 3)
                  mst.a(#args == 0)
                  scr:poll()
                  mst.a(#args == 2)
                  mst.a(mst.repr_equal(args, {{1, 2, 3}, {true, true, true}}))
                  scr:poll()
                  mst.a(#args == 3)
                  mst.a(mst.repr_equal(args, {{1, 2, 3}, 
                                              {true, true, true},
                                              {true, true, true},
                                             }))

                   end)
            it("calls single-use only once", function ()
                  local scr = scr.scr:new{}
                  local w, nc = create_nopworker()
                  scr:run(w)
                  mst.a(nc[1] == 0)
                  scr:poll()
                  mst.a(nc[1] == 1)
                  scr:poll()
                  mst.a(nc[1] == 1)
                   end)
            it("calls double-use only twice #twice", function ()
                  local scr = scr.scr:new{}
                  local w, nc = create_nopworker(1)
                  scr:run(w)
                  mst.a(nc[1] == 0)
                  scr:poll()
                  mst.a(nc[1] == 2)
                  scr:poll()
                  mst.a(nc[1] == 2)
                                              end)
end)
