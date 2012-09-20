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
-- Last modified: Thu Sep 20 13:59:35 2012 mstenber
-- Edit time:     37 min
--

require "luacov"
require "busted"
require "scb"
require "mst"
require 'ssloop'

local loop = ssloop.loop()

function create_dummy_l_c(port, receiver)
   -- assume receiver is a coroutine
   local d = {host='localhost', port=port, 
              --debug=true,
              callback=function (c)
                 --print('create_dummy_l_c - got new connection', c)
                 function c:callback(r)
                    -- resume the receiver coroutine
                    --print('got read callback')
                    r, err = coroutine.resume(receiver, r)
                    assert(r, "coroutine resume failed")
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
   local cr = coroutine.create(function ()
                                  local c = 0
                                  while true
                                  do
                                     --print('dummy receiver coroutine', c)
                                     local r = coroutine.yield()
                                     c = c + #r
                                     if c == n
                                     then
                                        loop:unloop()
                                        break
                                     end
                                  end
                                  -- final yield
                                  coroutine.yield()
                               end)
   return cr
end

describe("no-boom-init-test", function ()
            it("can create sockets", function ()
                  local cr = create_dummy_receiver(1)
                  local l, c = create_dummy_l_c(12444, cr)
                  assert(l ~= nil, "no listener")
                  assert(c ~= nil, "no caller")
                  --print('c is', c, c:tostring())
                  c:write('1')
                  --print('run_loop_awhile')
                  ssloop.run_loop_awhile()
                  --print('trying to resume coroutine once more - should be dead')
                  r, err = coroutine.resume(cr)
                  assert(not r, "coroutine still active")
                  l:done()
                  c:done()
                                     end)
                              end)

