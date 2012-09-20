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
-- Last modified: Wed Sep 19 22:54:12 2012 mstenber
-- Edit time:     25 min
--

require "luacov"
require "busted"
require "scb"
require "mst"

local loop = ev.Loop.default

function create_dummy_l_c(port, receiver)
   -- assume receiver is a coroutine
   local d = {host='localhost', port=port, 
              debug=true,
              callback=function (c)
                 print('got new connection', c)
                 function c:callback(r)
                    -- resume the receiver coroutine
                    print('got read callback')
                    r, err = receiver.resume(r)
                    assert(r)
                 end
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
   mst.run_loop_awhile()
   c = r[1]
   print('wait_connected done')
   assert(c)
   return c
end

function create_dummy_receiver(n)
   local cr = coroutine.create(function ()
                                  local c = 0
                                  while true
                                  do
                                     local r = coroutine.yield()
                                     c = c + #r
                                     if c == n
                                     then
                                        loop:unloop()
                                        break
                                     end
                                  end
                               end)
   return cr
end

describe("no-boom-init-test", function ()
            it("can create sockets", function ()
                  local dr = create_dummy_receiver(1)
                  local l, c = create_dummy_l_c(12444, cr)
                  assert(l ~= nil)
                  assert(c ~= nil)
                  print('c is', c, c:tostring())
                  c:write('1')
                  print('run_loop_awhile')
                  mst.run_loop_awhile()
                  print('trying to resume coroutine once more - should be dead')
                  r, err = coroutine.resume(dr)
                  assert(not r, "coroutine still active")
                  l:done()
                  c:done()
                                     end)
                              end)

