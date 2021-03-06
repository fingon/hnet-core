#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Sep 18 12:25:32 2012 mstenber
-- Last modified: Wed Jul 17 12:16:42 2013 mstenber
-- Edit time:     190 min
--

require "busted"
require "mst"
require 'mst_test'
require 'ssloop'

local run_loop_awhile = ssloop.run_loop_awhile
local run_loop_until = ssloop.run_loop_until
local add_eventloop_terminator = mst_test.add_eventloop_terminator
local inject_refcounted_terminator = mst_test.inject_refcounted_terminator

local _skv = require 'skv'
local skv = _skv.skv
local loop = ssloop.loop()
require 'skv_const'

module("skv_spec", package.seeall)

-- as this stuff uses the skv fsm in somewhat abusive fashion, we tune
-- the timeouts to 'low' values (by default, starting up two instances
-- at same time without setting one of them e.g. as server isn't
-- probably really sensible)

-- connect timeout shouldn't occur anyway, so we just fudge the listen
-- timeout so that if listen fails,
skv_const.INITIAL_LISTEN_TIMEOUT=0.01
--skv_const.CONNECT_TIMEOUT=0.1

local _availport = 14400

function get_available_port()
   local sp = _availport
   _availport = _availport + 1
   return sp
end

-- we don't care about rest of the module

local CLIENT_STATE_NAME = 'Client.WaitUpdates'
local SERVER_STATE_NAME = 'Server.WaitConnections'

local DUMMY_KEY11 = 'foo1'
local DUMMY_KEY21 = 'bar1'
local DUMMY_KEY12 = 'foo2'
local DUMMY_KEY22 = 'bar2'


describe("class init", 
         function()
            before_each(function ()
                     local r = loop:clear()
                     mst.a(not r, 'something left dangling (setup)', r)
                  end)
            after_each(function ()
                        loop:clear()
                        -- we intentionally clear it first
                        local r = loop:clear()
                        mst.a(not r, 'something left dangling (td)', r)
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
                  loop:loop_until(function ()
                                     return o.fsm:getState().name == 
                                        "Server.WaitConnections"
                                  end)
               end)
            it("cannot be created [non-long lived]", 
               function()
                  local o = skv:new{long_lived=false
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

local function setup_client_server(base_c)
   mst.d('setup_client_server')
   local port = get_available_port()
   local o1 = skv:new{long_lived=true, port=port}
   local o2 = skv:new{long_lived=true, port=port}
   -- insert conditional closing stuff
   local c = {base_c}
   
   for _, o in ipairs{o1, o2}
   do
      inject_refcounted_terminator(o, 'new_client', c)
      inject_refcounted_terminator(o.fsm, 'ReceiveVersion', c)
   end
   mst.d(' run_loop_awhile')
   run_loop_awhile()
   mst.d(' run_loop_awhile done')
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
   mst.d('setup_client_server done')


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

local function test_state_propagation_int(src, dst, k1, k2, st1, st2, st3)
   st1 = st1 or "bar"
   st2 = st2 or "baz"
   st3 = st3 or "bazinga"
   mst.a(src and dst)
   src:set(k1, st1)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get(k1) == st1
      end)

   src:set(k2, st3)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get(k2) == st3
      end)

   src:set(k1, st2)
   run_loop_until(
      function ()
         --ensure_sane(src)
         --ensure_sane(dst)
         return dst:get(k1) == st2
      end)
end

function test_state_propagation(o1, o2, st1, st2, st3)
   test_state_propagation_int(o1, o2, DUMMY_KEY11, DUMMY_KEY21, st1, st2, st3)
   test_state_propagation_int(o2, o1, DUMMY_KEY21, DUMMY_KEY22, st1, st2, st3)
end

describe("class working (ignoring setup)", function()
            before_each(function ()
                     local r = loop:clear()
                     mst.a(not r, 'something left dangling (setup)', r)
                  end)
            after_each(function ()
                        loop:clear()
                        -- we intentionally clear it first
                        local r = loop:clear()
                        mst.a(not r, 'something left dangling (td)', r)
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
                  local s = skv:new{long_lived=true, port=port}
                  local c = skv:new{long_lived=false, auto_retry=true, port=port}
                  test_state_propagation(s, c)
                                      end)

            it("transmits data c->s->c [nowait]", function ()
                  local port = get_available_port()
                  local s = skv:new{long_lived=true, port=port}
                  local c1 = skv:new{long_lived=false, auto_retry=true, port=port}
                  local c2 = skv:new{long_lived=false, auto_retry=true, port=port}
                  test_state_propagation(c1, c2)
                                      end)

            it("transmits data c->s->c [wait] #wc", function ()
                  local port = get_available_port()
                  local s = skv:new{long_lived=true, server=true, port=port}
                  local c1 = skv:new{long_lived=false, port=port}
                  c1:connect()
                  local c2 = skv:new{long_lived=false, port=port}
                  c2:connect()
                  test_state_propagation(c1, c2)
                                      end)
            
                                           end)

describe("class working (post setup) #clear", function()
            before_each(function ()
                     local r = loop:clear()
                     mst.a(not r, 'something left dangling (setup)', r)
                  end)
            after_each(function ()
                        local r = loop:clear()
                        mst.a(not r, 'something left dangling (td)', r)
                     end)
            it("should transfer state across (c->s) #pcs", function()
                  mst.d('!!! init')
                  local c, s, h = mst.d_xpcall(
                     function ()
                        return setup_client_server(2)
                     end)
                  mst.d('!!! test_state_propagation')
                  test_state_propagation(c, s)
                  mst.d('!!! s/c done')
                  mst.d_xpcall(
                     function ()
                        c:done()
                        s:done()
                     end)
                  mst.d('!!! over')
              end)
            it("should transfer state across (s->c) #psc", function()
                  local c, s, h = setup_client_server(2)
                  test_state_propagation(s, c)
                  c:done()
                  s:done()
              end)
            it("test change notifications #cn", function()
                  local c, s, h = setup_client_server(2)
                  
                  local calls = {0, 0}
                  -- this occurs twice
                  local fun1 = function (k, v)
                     mst.a(k == DUMMY_KEY11)
                     calls[2] = calls[2] + 1
                  end
                  local fun3 = function (k, v)
                     mst.a(k == DUMMY_KEY11)
                     calls[2] = calls[2] + 1
                  end
                  local fun2 = function (k, v)
                     calls[1] = calls[1] + 1
                  end

                  s:add_change_observer(fun1, DUMMY_KEY11)
                  s:add_change_observer(fun3, DUMMY_KEY11)
                  -- these occur 2x each (due to foo changing twice)

                  s:add_change_observer(fun2)
                  -- this occurs 3 times (2x foo, 1x bar) *2 (both ways)

                  test_state_propagation(c, s)
                  mst_test.assert_repr_equal(calls[1], 3 * 2)
                  mst_test.assert_repr_equal(calls[2], 4)
                  s:remove_change_observer(fun2)
                  s:remove_change_observer(fun1, DUMMY_KEY11)
                  s:remove_change_observer(fun3, DUMMY_KEY11)
                  mst.enable_assert = false
                  assert.error(function ()
                                  s:remove_change_observer(fun1)
                               end)
                  mst.enable_assert = true
                  mst.a(mst.table_is_empty(s.change_events, 'remaining change_events'))
                  c:done()
                  s:done()

              end)
            it("client should reconnect if server disconnects suddenly",
               function()
                  local c, s, h = setup_client_server(2)

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
                  c:done()
                  s:done()
               end)
         end)

describe("skv-client", function ()
            it("connect-fail", function ()
                  local port = get_available_port()
                  -- try to connect to non local port -> should fail
                  -- (and not with timeout)
                  local skv = skv:new{long_lived=false, port=port}
                  local r, err = skv:connect(12345)
                  mst.a(not r)
                  mst.a(err)
                  skv:done()
                   end)
            it("connect-ok #conn", function ()
                  local port = get_available_port()
                  -- try to connect to non local port -> should fail
                  -- (and not with timeout)
                  local skv2 = skv:new{long_lived=true, server=true, port=port}
                  skv2:set('foo', 'bar')
                  local skv = skv:new{long_lived=false, port=port}
                  local r, err = skv:connect(12345)
                  mst.a(r, 'hrm, even valid connect failed', r, err)
                  local r = skv:get('foo')
                  mst.d('got', r)
                  mst.a(r == 'bar')


                  -- make sure the synchronous set also works
                  skv:set('bar', 'baz')
                  local r = skv:wait_in_sync()
                  mst.a(r, 'wait_in_sync timed out')
                  mst.a(skv2:get('bar') == 'baz')

                  -- make sure clearing works too
                  skv:clear()
                  local r = skv:wait_in_sync()
                  mst.a(r, 'wait_in_sync timed out')
                  mst.a(skv:get('bar') == false)
                  mst.a(skv2:get('bar') == false)


                  skv:done()
                  skv2:done()
                   end)
             end)
