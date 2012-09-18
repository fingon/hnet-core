#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Tue Sep 18 12:25:32 2012 mstenber
-- Last modified: Tue Sep 18 15:19:33 2012 mstenber
-- Edit time:     16 min
--

require "luacov"
require "busted"
local ev = require "ev"

local skv = require 'skv'

local function run_loop_awhile(loop)
   ev.Timer.new(function(loop,timer,revents)
                   --print 'done'
                   loop:unloop()
                end, 0.5):start(loop)
   loop:loop()
end

local function add_eventloop_terminate_mock(o, n)
   local loop = ev.Loop.default
   local f = o[n]
   o[n] = function (...)
      loop:unloop()
      f(...)
   end
end

describe("class init", 
         function()
            it("cannot be created w/o loop", 
               function()
                  assert.error(function()
                                  local o = skv:new()
                               end)
               end)
            it("can be created [long lived]", 
               function()
                  local loop = ev.Loop.default
                  local o = skv:new{loop=loop, long_lived=true,
                                   port=12345}
                  --run_loop_awhile(loop)
               end)
            it("cannot be created [non-long lived]", 
               function()
                  local loop = ev.Loop.default
                  local o = skv:new{loop=loop, long_lived=false
--                                    ,debug=true
                                    ,port=12346
                                   }
                  add_eventloop_terminate_mock(o, 'fail')
                  run_loop_awhile(loop)
                  assert.truthy(o.error)
               end)
         end)

