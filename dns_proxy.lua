#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_proxy.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Apr 29 18:16:53 2013 mstenber
-- Last modified: Tue Apr 30 17:49:28 2013 mstenber
-- Edit time:     75 min
--

-- This is minimalist DNS proxy implementation.

-- Whole design is written around coroutines, as they make ~low-impact
-- handling of LARGE number of requests possible.

-- The way of handling 'too many' requests is simple; we maintain
-- ordered data structure of events, and have two different strategies
-- available:

-- - drop oldest (requires FIFO data structure with fast seek)
-- - prevent new (just require # in flight number)
-- XXX - choose

-- XXX - see if {tcp,udp}_handler subclasses are even needed. with the
-- channel abstraction, they might not be.

-- Architecturally, 'handler' is responsible for single socket (see
-- diagrams). It provides a way of getting a request, and sending a
-- reply to it. Requests and replies are handled in a loop, and it is
-- assumed that the loop is started as a coroutine using scr
-- framework+reactor.

require 'mst'
require 'scr'
require 'scb'
require 'scbtcp'


module(..., package.seeall)

handler = mst.create_class{class='handler', mandatory={"c"}}

function handler:init()
   self.stopped = true
   self:start()
end

function handler:uninit()
   self:stop()
   -- kill the underlying channel too
   self.c:done()
end

function handler:start()
   if not self.stopped
   then
      return
   end
   self.stopped = nil
   scr.run(self.loop, self)
end

function handler:stop()
   -- loop shouldn't even resume, if things happen correctly, but at
   -- least it should never send a reply any more..
   self.stopped = true
end

function handler:loop()
   while true
   do
      -- subclass responsibility
      local r, src = self:read_request()
      if self.stopped then return end
      if r
      then
         scr.run(self.handle_request, self, r, src)
      end
   end
end

function handler:handle_request(msg, src)
   self:d('handle_request', msg, src)

   local reply

   -- for test purposes, just return request
   reply = msg

   if self.stopped then return end
   self:d('sending reply', reply)
   if reply
   then
      -- subclass responsibility
      self:send_response(reply, src)
   end
end

tcp_handler = handler:new_subclass{class='tcp_handler'}

function tcp_handler:read_request()
   error("not implemented yet")
end

function tcp_handler:send_response(r, dst)
   error("not implemented yet")
end

udp_handler = handler:new_subclass{class='tcp_handler'}

function udp_handler:read_request()
   return self.c:receive_msg()
end

function udp_handler:send_response(msg, dst)
   self:a(dst, 'no destination')
   self.c:send_msg(msg, dst)
end

dns_proxy = mst.create_class{class='dns_proxy'}

function dns_proxy:init()
   -- create UDP channel
   local udp_c = dns_channel.get_udp_channel{port=self.udp_port}
   -- and then associate handler with it
   self.udp = udp_handler:new{c=udp_c}
   self.udp:start()

   local tcp_port = self.tcp_port or self.port or dns_const.PORT
   local tcp_s = scbtcp.create_listener{host='*', port=tcp_port}
   self.tcp_s = scr.wrap_socket(tcp_s)
   
   -- fire off coroutine; we get rid of it by killing the tcp_s..
   scr.run(function ()
              while true
              do
                 local c = self.tcp_s:accept()
                 -- XXX - do we need to keep track of these handlers?
                 -- or just fire and forget?
                 local h = tcp_handler:new{s=c}
                 h:start()
              end
           end)
end

function dns_proxy:uninit()
   self.udp:done()
   self.tcp_s:done()
end

