#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scr_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Apr 25 10:54:26 2013 mstenber
-- Last modified: Fri May  3 12:36:01 2013 mstenber
-- Edit time:     59 min
--

-- Simple testsuite for complex stuff - simple coroutine reactor tests

require "busted"
require "scr"
require "scb"
require "scbtcp"

module("scr_spec", package.seeall)

-- lazyworker runs every N calls; return value is call + #calls object
function create_lazyworker(n)
   local ncalls = {0}
   local function x()
      local ccalls = 0
      local function y()
         ccalls = ccalls + 1
         return ccalls % n == 0
      end
      while true
      do
         -- we've been called
         ncalls[1] = ncalls[1] + 1
         coroutine.yield(y)
      end
   end
   return x, ncalls
end

local function always_true()
   return true
end

function create_storeworker()
   local args = {}
   local function x(...)
      table.insert(args, {...})
      while true
      do
         local y = always_true
         local r = {coroutine.yield(y, y, y)}
         table.insert(args, r)
      end
   end
   return x, args
end

function create_nopworker(nyields)
   local ncalls = {0}
   local function x()
      mst.d('nopworker starting')
      ncalls[1] = ncalls[1] + 1
      local c = nyields or 0
      for i=1,c
      do
         mst.d('nopworker yielding')
         coroutine.yield(always_true)
         ncalls[1] = ncalls[1] + 1
      end
      mst.d('nopworker done')

   end
   return x, ncalls
end

describe("scr", function ()
            it("works", function ()
                  local scr = scr.scr:new{}
                  local w, ncalls = create_lazyworker(3)

                  scr:run(w)
                  -- rtc completion => first call (+ first call to check)
                  scr:poll()
                  mst.a(ncalls[1] == 1, ncalls)
                  scr:poll()
                  mst.a(ncalls[1] == 1)
                  scr:poll()

                  mst.a(ncalls[1] == 2)

                        end)
            it("arguments passed as they should be #ar", function ()
                  local scr = scr.scr:new{}
                  local w, args = create_storeworker()
                  scr:run(w, 1, 2, 3)
                  mst.a(#args == 0)
                  scr:poll()
                  mst.a(#args == 2)
                  mst.a(mst.repr_equal(args, {{1, 2, 3}, {true, true, true}}))
                  scr:poll()
                  mst.a(#args == 3)
                  mst.a(mst.repr_equal(args, {{1, 2, 3}, 
                                              {true, true, true},
                                              {true, true, true},
                                             }))

                                                         end)
            it("calls single-use only once", function ()
                  local scr = scr.scr:new{}
                  local w, nc = create_nopworker()
                  scr:run(w)
                  mst.a(nc[1] == 0)
                  scr:poll()
                  mst.a(nc[1] == 1)
                  scr:poll()
                  mst.a(nc[1] == 1)
                                             end)
            it("calls double-use only twice #twice", function ()
                  local scr = scr.scr:new{}
                  local w, nc = create_nopworker(1)
                  scr:run(w)
                  mst.a(nc[1] == 0)
                  scr:poll()
                  mst.a(nc[1] == 2)
                  scr:poll()
                  mst.a(nc[1] == 2)
                                                     end)
                end)

describe("scrsocket", function ()
            it("works with 2 basic udp sockets", function ()
                  local thost = scb.LOCALHOST
                  local p1 = 13542

                  local rs1 = scb.create_udp_socket{host=thost, port=0}
                  local rs2 = scb.create_udp_socket{host=thost, port=p1}
                  local s1 = scr.wrap_socket(rs1)
                  local s2 = scr.wrap_socket(rs2)
                  
                  local echoserver = scr.run(function ()
                                                while true
                                                do
                                                   local r, ip, port = 
                                                      s2:receivefrom()
                                                   s2:sendto(r, ip, port)
                                                end
                                             end)
                  local i = 1
                  local echoclient = scr.run(function ()
                                                while true
                                                do
                                                   s = tostring(i)
                                                   s1:sendto(s, thost, p1)
                                                   local r = s1:receivefrom()
                                                   mst.a(s == r)
                                                   i = i + 1
                                                end
                                             end)
                  local r = ssloop.loop():loop_until(function ()
                                                        return i == 100
                                                     end, 10)
                  mst.a(r, 'timed out - unable to handle 10 msg/s?')

                  s1:done()
                  s2:done()

                  scr.clear_scr()
                                                 end)


            it("works with 2 basic tcp sockets #tcp", function ()
                  -- basic idea: double the size of packet, until it
                  -- comes partially. do two partial sends, and then
                  -- call it a day if everything comes through as it
                  -- should.

                  -- default payload
                  local b = '1234567890'
                  local thost = scb.LOCALHOST
                  local p1 = 13542

                  local rs2 = scbtcp.create_listener{host=thost, port=p1}
                  local rs1 = scbtcp.create_socket{host=thost}
                  local s1 = scr.wrap_socket(rs1)
                  local s2 = scr.wrap_socket(rs2)
                  local stopped, stopping
                  
                  local echoserver = scr.run(function ()
                                                while true
                                                do
                                                   mst.d('server accept')
                                                   local c = s2:accept()
                                                   scr.run(function ()
                                                              while true
                                                              do
                                                                 mst.d('server receive')
                                                                 local r, err = c:receive()
                                                                 mst.d('server got', r, err)
                                                                 if not r 
                                                                 then 
                                                                    stopped = true
                                                                    return 
                                                                 end
                                                                 c:send(r)
                                                              end
                                                           end)
                                                end
                                             end)
                  local frag = 0
                  local echoclient = scr.run(function ()
                                                mst.d('calling connect')

                                                local r, err = s1:connect(thost, p1)
                                                mst.a(r, 'connect failed', err)
                                                while true
                                                do
                                                   mst.d('client write', #b)
                                                   s1:send(b)
                                                   local got = 0
                                                   while got < #b
                                                   do
                                                      if got>0
                                                      then
                                                         frag = frag + 1
                                                      end
                                                      local r = s1:receive()

                                                      mst.a(r)
                                                      got = got + #r
                                                      mst.d('client got', #r)
                                                      if not r then return end
                                                   end
                                                   mst.a(got == #b, 'got too much', got, #b)

                                                   -- double size
                                                   -- (to make sure we get fragmented reads at some point)
                                                   if stopping then break end
                                                   b = b .. b
                                                end
                                                -- close the socket
                                                s1:done()
                                             end)
                  local r = ssloop.loop():loop_until(function ()
                                                        return frag > 0 and #b > 2^17
                                                     end, 1)
                  mst.a(r, 'timed out 1')
                  stopping = true
                  local r = ssloop.loop():loop_until(function ()
                                                        return stopped
                                                     end, 1)
                  mst.a(r, 'timed out 1')

                  s2:done()
                  scr.clear_scr()
                                                 end)

                      end)
