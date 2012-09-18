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
-- Last modified: Tue Sep 18 16:26:15 2012 mstenber
-- Edit time:     37 min
--

require "luacov"
require "busted"
local ev = require "ev"

local skv = require 'skv'

TEST_TIMEOUT_INVALID=3
local CLIENT_STATE_NAME = 'Client.WaitUpdates'
local SERVER_STATE_NAME = 'Server.WaitConnections'

local function run_loop_awhile(loop, timeout)
   timeout = timeout or TEST_TIMEOUT_INVALID
   ev.Timer.new(function(loop,timer,revents)
                   --print 'done'
                   loop:unloop()
                end, timeout):start(loop)
   loop:loop()
end

local function inject_snitch(o, n, sf)
   local f = o[n]
   o[n] = function (...)
      sf(...)
      f(...)
   end
   
end

local function add_eventloop_terminate_mock(o, n)
   local loop = ev.Loop.default
   inject_snitch(o, n, function ()
                    loop:unloop()
                       end)
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
                  o:done()
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
                  o:done()
               end)
         end)

local function setup_client_server()
   local loop = ev.Loop.default
   local o1 = skv:new{loop=loop, long_lived=true, port=12347}
   local o2 = skv:new{loop=loop, long_lived=true, port=12347}
   -- insert conditional closing stuff
   local c = {0}
   local terminator = function ()
      c[1] = c[1] + 1
      if c[1] == 2
      then
         loop:unloop()
      end
   end
   
   for _, o in ipairs{o1, o2}
   do
      inject_snitch(o, 'new_client', terminator)
      inject_snitch(o.fsm, 'Connected', terminator)
   end
   run_loop_awhile(loop)
   local s1 = o1.fsm:getState().name
   local s2 = o2.fsm:getState().name

   -- one should become server, other client (two
   -- servers coming up on _same_ eventloop cycle
   -- should not work with same port)
   if s1 == CLIENT_STATE_NAME
   then
      assert(s2 == SERVER_STATE_NAME)
      return o1, o2
   end
   assert(s1 == SERVER_STATE_NAME)
   assert(s2 == CLIENT_STATE_NAME)
   return o2, o1
end

describe("class working",
         function()
            it("should work fine with 2 instances",
               function()
                  local loop = ev.Loop.default
                  local c, s = setup_client_server()
                  --run_loop_awhile(loop)
               end)
         end)
