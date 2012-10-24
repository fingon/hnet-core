#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scb_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Wed Sep 19 22:04:54 2012 mstenber
-- Last modified: Thu Oct 11 11:55:25 2012 mstenber
-- Edit time:     104 min
--

require "busted"
require "scb"
require "mst"
require 'ssloop'

module("ssloop_spec", package.seeall)

local loop = ssloop.loop()

MAGIC='<data>'
MAGIC2='<eof>'

function create_dummy_l_c(port, receiver)
   -- assume receiver is a coroutine
   local d = {host='localhost', port=port, 
              callback=function (c)
                 mst.d('create_dummy_l_c - got new connection', c)
                 function c.callback(d)
                    -- resume the receiver coroutine
                    mst.d('got read callback', #d)
                    local r, err = coroutine.resume(receiver, d)
                    if not r
                    then
                       error("coroutine resume failed " .. err)
                    else
                       mst.a(err == MAGIC or err == MAGIC2,
                             "invalid magic from coroutine", r, err)
                    end
                    mst.d('read callback done')
                 end
                 mst.d('create_dummy_l_c - done')
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
   mst.d('wait_connected done')
   mst.a(c, "no socket in wait_connected")
   return c
end

function create_dummy_receiver(n)
   local rh = {0}
   local cr = coroutine.create(function (data)
                                  while true
                                  do
                                     mst.d('coroutine resumed', tostring(data))
                                     rh[1] = rh[1] + #data
                                     if rh[1] == n
                                     then
                                        loop:unloop()
                                        mst.d('coroutine done')
                                        return MAGIC2
                                     end
                                     data = coroutine.yield(MAGIC)
                                  end
                               end)

   -- start it - it should be waiting at the first yield for data
   --local r, err = coroutine.resume(cr)

   --mst.a(r, "coroutine resume failed even at start")
   --mst.a(err == MAGIC)

   return cr, rh
end


function test_once(n, port)
   local cr, rh = create_dummy_receiver(n)
   local l, c = create_dummy_l_c(port, cr)
   mst.a(l ~= nil, "no listener")
   mst.a(c ~= nil, "no caller")
   if n == 100000
   then
      mst.d('c is', c)
      for i=1, 1000
      do
         c:write(string.rep('1234567890', 10))
      end
   elseif n == 1
   then
      c:write('1')
   else
      error('unsupported size')
   end
   mst.d('run_loop_awhile')
   ssloop.run_loop_awhile()

   mst.d('trying to resume coroutine once more - should be dead')
   local r, err = coroutine.resume(cr)
   mst.a(not r, "coroutine still active")
   mst.a(rh[1] == n, "did not receive anything? " .. tostring(rh[1]))
end

describe("scb-test", function ()
            before_each(function ()
                           local r = loop:clear()
                           mst.a(not r, 'left before', r)
                  end)
            after_each(function ()
                        loop:clear()
                        local r = loop:clear()
                        mst.a(not r, 'left after', r)
                     end)
            it("can create sockets #byte", function ()
                  mst.d_xpcall(function ()
                                  test_once(1, 12444)
                               end)
                                     end)

            it("can transfer 100k", function ()
                  test_once(100000, 12445)
                                     end)
            

                              end)


