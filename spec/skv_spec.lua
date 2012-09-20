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
-- Last modified: Thu Sep 20 15:07:37 2012 mstenber
-- Edit time:     68 min
--

require "luacov"
require "busted"
require "mst"
require 'ssloop'

local run_loop_awhile = ssloop.run_loop_awhile
assert(run_loop_awhile)
local add_eventloop_terminator = ssloop.add_eventloop_terminator
assert(add_eventloop_terminator)
local inject_refcounted_terminator = ssloop.inject_refcounted_terminator
assert(inject_refcounted_terminator)

local _skv = require 'skv'
local skv = _skv.skv
local loop = ssloop.loop()


-- we don't care about rest of the module

local CLIENT_STATE_NAME = 'Client.WaitUpdates'
local SERVER_STATE_NAME = 'Server.WaitConnections'

describe("class init", 
         function()
            setup(function ()
                     assert(#loop.r == 0, "some readers left")
                     assert(#loop.w == 0, "some writers left")
                     assert(#loop.t == 0, "some timeouts left")
                  end)
            teardown(function ()
                        loop:done()
                     end)
            it("cannot be created w/o loop", 
               function()
                  assert.error(function()
                                  local o = skv:new()
                               end)
               end)
            it("can be created [long lived]", 
               function()
                  local o = skv:new{long_lived=true, port=12345}
                  add_eventloop_terminator(o, 'start_wait_connections')
                  run_loop_awhile()
                  assert.are.same(o.fsm:getState().name, 
                                  "Server.WaitConnections")
               end)
            it("cannot be created [non-long lived]", 
               function()
                  local o = skv:new{long_lived=false
                                    --  ,debug=true
                                    ,port=12346
                                   }
                  add_eventloop_terminator(o, 'fail')
                  run_loop_awhile()
                  assert.truthy(o.error)
                  --print(o.fsm:getState().name)
                  assert.are.same(o.fsm:getState().name, 
                                  "Terminal.ClientFailConnect")
               end)
         end)

local function setup_client_server(base_c, port, debug)
   local o1 = skv:new{long_lived=true, port=port, debug=debug}
   local o2 = skv:new{long_lived=true, port=port, debug=debug}
   -- insert conditional closing stuff
   local c = {base_c}
   
   for _, o in ipairs{o1, o2}
   do
      inject_refcounted_terminator(o, 'new_client', c)
      inject_refcounted_terminator(o.fsm, 'Connected', c)
   end
   run_loop_awhile()
   local s1 = o1.fsm:getState().name
   local s2 = o2.fsm:getState().name

   -- one should become server, other client (two
   -- servers coming up on _same_ eventloop cycle
   -- should not work with same port)
   if s1 == CLIENT_STATE_NAME
   then
      assert.are.same(s2, SERVER_STATE_NAME)
      return o1, o2, c
   end
   assert.are.same(s1, SERVER_STATE_NAME)
   assert.are.same(s2, CLIENT_STATE_NAME)
   return o2, o1, c
end

describe("class working", function()
            setup(function ()
                     assert(#loop.r == 0, "some readers left")
                     assert(#loop.w == 0, "some writers left")
                     assert(#loop.t == 0, "some timeouts left")
                  end)
            teardown(function ()
                        loop:done()
                     end)
            it("should work fine with 2 instances", function()
                  local c, s, h = setup_client_server(2, 12347--, true
                                                     )
                  loop:done()
               end)
            it("client should reconnect if server disconnects suddenly",
               function()
                  local c, s, h = setup_client_server(2, 12348)

                  -- ok, we simulate server disconnect and expect 3
                  -- events to happen - client should get conn closed,
                  -- and new connection; server should get also new connection
                  inject_refcounted_terminator(c.fsm, 'ConnectionClosed', h)
                  h[1] = 3

                  n = 0
                  for k, v in pairs(s.connections)
                  do
                     k:done()
                     n = n + 1
                  end
                  assert.are.same(n, 1)
                  -- should get new new_client, and new connected from server
                  run_loop_awhile()
                  local cs1 = c.fsm:getState().name
                  local cs2 = s.fsm:getState().name
                  assert.are.same(h[1], 0)
                  assert.are.same(cs1, CLIENT_STATE_NAME)
                  assert.are.same(cs2, SERVER_STATE_NAME)
                  loop:done()
               end)
         end)
