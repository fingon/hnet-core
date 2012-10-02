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
-- Last modified: Tue Oct  2 13:42:01 2012 mstenber
-- Edit time:     123 min
--

require "busted"
require "mst"
require 'ssloop'

local run_loop_awhile = ssloop.run_loop_awhile
local run_loop_until = ssloop.run_loop_until
local add_eventloop_terminator = ssloop.add_eventloop_terminator
local inject_refcounted_terminator = ssloop.inject_refcounted_terminator

local _skv = require 'skv'
local skv = _skv.skv
local loop = ssloop.loop()


local _availport = 14400

function get_available_port()
   local sp = _availport
   _availport = _availport + 1
   return sp
end

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
                        loop:clear()
                     end)
            it("cannot be created w/o loop", 
               function()
                  assert.error(function()
                                  local o = skv:new()
                               end)
               end)
            it("can be created [long lived]", 
               function()
                  local o = skv:new{long_lived=true, port=get_available_port()}
                  add_eventloop_terminator(o, 'start_wait_connections')
                  run_loop_awhile()
                  assert.are.same(o.fsm:getState().name, 
                                  "Server.WaitConnections")
               end)
            it("cannot be created [non-long lived]", 
               function()
                  local o = skv:new{long_lived=false
                                    --  ,debug=true
                                    ,port=get_available_port()
                                   }
                  add_eventloop_terminator(o, 'fail')
                  run_loop_awhile()
                  assert.truthy(o.error)
                  --print(o.fsm:getState().name)
                  assert.are.same(o.fsm:getState().name, 
                                  "Terminal.ClientFailConnect")
               end)
         end)

local function setup_client_server(base_c, debug)
   local port = get_available_port()
   --mst.debug = debug
   local o1 = skv:new{long_lived=true, port=port, debug=debug}
   local o2 = skv:new{long_lived=true, port=port, debug=debug}
   -- insert conditional closing stuff
   local c = {base_c}
   
   for _, o in ipairs{o1, o2}
   do
      inject_refcounted_terminator(o, 'new_client', c)
      inject_refcounted_terminator(o.fsm, 'ReceiveVersion', c)
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

local function ensure_sane(s)
   local l = s:get_jsoncodecs()
   --mst.a(#l > 0, "no jsoncodects for", s)

   for i, v in ipairs(l)
   do
      mst.a(v.read < 500, "too much read!", s, v)
      mst.a(v.written < 500, "too much written!", s, v)
   end
end

local function test_state_propagation(src, dst, st1, st2, st3)
   st1 = st1 or "bar"
   st2 = st2 or "baz"
   st3 = st3 or "bazinga"

   src:set("foo", st1)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get("foo") == st1
      end)

   src:set("bar", st3)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get("bar") == st3
      end)

   src:set("foo", st2)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get("foo") == st2
      end)
end

describe("class working (ignoring setup)", function()
            setup(function ()
                     assert(#loop.r == 0, "some readers left")
                     assert(#loop.w == 0, "some writers left")
                     assert(#loop.t == 0, "some timeouts left")
                  end)
            teardown(function ()
                        loop:clear()
                     end)

            it("transmits data [nowait]", function ()
                  local port = get_available_port()
                  local o1 = skv:new{long_lived=true, port=port}
                  local o2 = skv:new{long_lived=true, port=port}
                  test_state_propagation(o1, o2)
                  -- 10kb payload
                  test_state_propagation(o1, o2, string.rep('1234567890', 1000))
                                          end)


            it("transmits data c->s [nowait] #cs", function ()
                  local port = get_available_port()
                  local s = skv:new{long_lived=true, port=port}
                  local c = skv:new{long_lived=false, auto_retry=true, port=port}
                  test_state_propagation(c, s)
                                 end)

            it("transmits data s->c [nowait] #sc", function ()
                  local port = get_available_port()
                  local debug = true
                  local debug = false
                  local s = skv:new{long_lived=true, port=port, debug=debug}
                  local c = skv:new{long_lived=false, auto_retry=true, port=port, debug=debug}
                  test_state_propagation(s, c)
                                      end)

            it("transmits data c->s->c [nowait]", function ()
                  local port = get_available_port()
                  local debug = true
                  local debug = false
                  local s = skv:new{long_lived=true, port=port, debug=debug}
                  local c1 = skv:new{long_lived=false, auto_retry=true, port=port, debug=debug}
                  local c2 = skv:new{long_lived=false, auto_retry=true, port=port, debug=debug}
                  test_state_propagation(c1, c2)
                                      end)
            
                                           end)

describe("class working (post setup)", function()
            setup(function ()
                     assert(#loop.r == 0, "some readers left")
                     assert(#loop.w == 0, "some writers left")
                     assert(#loop.t == 0, "some timeouts left")
                  end)
            teardown(function ()
                        loop:clear()
                     end)
            it("should transfer state across (c->s) #pcs", function()
                  local c, s, h = setup_client_server(2
                                                      --,true --debug
                                                     )
                  test_state_propagation(c, s)
              end)
            it("should transfer state across (s->c) #psc", function()
                  local c, s, h = setup_client_server(2
                                                      --,true --debug
                                                     )
                  test_state_propagation(s, c)
              end)
            it("test change notifications #cn", function()
                  local c, s, h = setup_client_server(2
                                                      --,true --debug
                                                     )
                  
                  local calls = {0, 0}
                  -- this occurs twice
                  local fun1 = function (k, v)
                     mst.a(k == "foo")
                     calls[2] = calls[2] + 1
                  end
                  local fun3 = function (k, v)
                     mst.a(k == "foo")
                     calls[2] = calls[2] + 1
                  end
                  local fun2 = function (k, v)
                     calls[1] = calls[1] + 1
                  end

                  s:add_change_observer(fun1, 'foo')
                  s:add_change_observer(fun3, 'foo')
                  -- these occur 2x each (due to foo changing twice)

                  s:add_change_observer(fun2)
                  -- this occurs 3 times (2x foo, 1x bar)

                  test_state_propagation(c, s)
                  mst.a(calls[1] == 3)
                  mst.a(calls[2] == 4)
                  s:remove_change_observer(fun2)
                  s:remove_change_observer(fun1, 'foo')
                  s:remove_change_observer(fun3, 'foo')
                  mst.enable_assert = false
                  assert.error(function ()
                                  s:remove_change_observer(fun1)
                               end)
                  mst.enable_assert = true
                  mst.a(mst.table_is_empty(s.change_events, 'remaining change_events'))

              end)
            it("client should reconnect if server disconnects suddenly",
               function()
                  local c, s, h = setup_client_server(2
                                                      --,true --debug
                                                     )

                  -- ok, we simulate server disconnect and expect 3
                  -- events to happen - client should get conn closed,
                  -- and new connection; server should get also new connection
                  inject_refcounted_terminator(c.fsm, 'ConnectionClosed', h)
                  h[1] = 3

                  local n = 0
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
                  ensure_sane(c)
                  ensure_sane(s)
               end)
         end)
