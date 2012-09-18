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
-- Last modified: Tue Sep 18 15:38:01 2012 mstenber
-- Edit time:     20 min
--

require "luacov"
require "busted"
local ev = require "ev"

local skv = require 'skv'

TEST_TIMEOUT_INVALID=3

local function run_loop_awhile(loop, timeout)
   timeout = timeout or TEST_TIMEOUT_INVALID
   ev.Timer.new(function(loop,timer,revents)
                   --print 'done'
                   loop:unloop()
                end, timeout):start(loop)
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
                  add_eventloop_terminate_mock(o, 'start_wait_connections')
                  run_loop_awhile(loop)
                  assert.are.same(o.fsm:getState().name, 
                                  "Server.WaitConnections")
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
                  --print(o.fsm:getState().name)
                  assert.are.same(o.fsm:getState().name, 
                                  "Terminal.ClientFailConnect")
               end)
         end)

