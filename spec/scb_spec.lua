#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scb_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Sep 19 22:04:54 2012 mstenber
-- Last modified: Thu Sep 20 15:44:49 2012 mstenber
-- Edit time:     69 min
--

require "luacov"
require "busted"
require "scb"
require "mst"
require 'ssloop'

local loop = ssloop.loop()

MAGIC='foo'
MAGIC2='bar'

function create_dummy_l_c(port, receiver, debug)
   -- assume receiver is a coroutine
   local d = {host='localhost', port=port, 
              debug=debug,
              callback=function (c)
                 print('create_dummy_l_c - got new connection', c)
                 function c.callback(d)
                    -- resume the receiver coroutine
                    print('got read callback', #d)
                    local r, err = coroutine.resume(receiver, d)
                    if not r
                    then
                       error("coroutine resume failed " .. err)
                    else
                       mst.a(err == MAGIC or err == MAGIC2,
                             "invalid magic from coroutine", r, err)
                    end
                    --print('read callback done')
                 end
                 --print('create_dummy_l_c - done')
                                                    end}
   local l = scb.new_listener(d)
   local c = scb.new_connect(d)
   c = wait_connected(c)
   return l, c
end

function wait_connected(c)
   local r = {}
   c.callback = function (c)
      r[1] = c
      loop:unloop()
   end
   ssloop.run_loop_awhile()
   c = r[1]
   --print('wait_connected done')
   assert(c, "no socket in wait_connected")
   return c
end

function create_dummy_receiver(n)
   local r = {0}
   local cr = coroutine.create(function (x)
                                  mst.a(not x, "initial resume arg", x)
                                  while true
                                  do
                                     local data = coroutine.yield(MAGIC)
                                     print('coroutine resumed', #data)
                                     r[1] = r[1] + #data
                                     if r[1] == n
                                     then
                                        loop:unloop()
                                        break
                                     end
                                  end
                                  return MAGIC2
                               end)
   -- start it - it should be waiting at the first yield for data
   coroutine.resume(cr)

   return cr, r
end


function test_once(n, debug)
   local cr, rh = create_dummy_receiver(n)
   local l, c = create_dummy_l_c(12444, cr, debug)
   assert(l ~= nil, "no listener")
   assert(c ~= nil, "no caller")
   if n == 100000
   then
      --print('c is', c, c:tostring())
      for i=1, 1000
      do
         c:write(string.rep('1234567890', 10))
      end
   elseif n == 1
   then
      c:write('1')
   else
      error()
   end
   --print('run_loop_awhile')
   ssloop.run_loop_awhile()
   --print('trying to resume coroutine once more - should be dead')
   r, err = coroutine.resume(cr)
   assert(not r, "coroutine still active")
   assert(rh[1] == n, "did not receive anything? " .. tostring(rh[1]))
end

describe("scb-test", function ()
            setup(function ()
                     assert(#loop.r == 0, "some readers left")
                     assert(#loop.w == 0, "some writers left")
                     assert(#loop.t == 0, "some timeouts left")
                  end)
            teardown(function ()
                        loop:done()
                        loop.debug = false
                     end)
            it("can create sockets", function ()
                  test_once(1)
                                     end)

            it("can transfer 100k", function ()
                  test_once(100000)
                                     end)
            

                              end)


