#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Tue Sep 18 12:23:19 2012 mstenber
-- Last modified: Tue Sep 18 16:55:52 2012 mstenber
-- Edit time:     107 min
--

local skv = {}
local skvclient = {}

-- first, skv

skv.__index = skv

local sm = require 'skv_sm'
local HOST = '127.0.0.1'
local PORT = 12345
local CONNECT_TIMEOUT = 0.1
local INITIAL_LISTEN_TIMEOUT = 0.2

local ERR_CONNECTION_REFUSED = "connection refused"

local ev = require 'ev'
require "socket"

local json = require "dkjson"

local function check_parameters(fname, o, l)
   for i, f in ipairs(l) do
      assert(o[f] ~= nil, f .. " is mandatory parameter to " .. fname)
   end
end

function skv:new(o)
   local o = o or {}
   o.host = o.host or HOST
   o.port = o.port or PORT
   check_parameters("skv:new", o, {"loop", "long_lived"})
   if o.debug
   then
      --local f = io.open('x.log', 'w')
      o.fsm = sm:new({owner=o, debugFlag=true})
   else
      o.fsm = sm:new({owner=o})
   end
   setmetatable(o, self)
   o.fsm:enterStartState()
   return o
end

-- we're done with the object -> clear state
function skv:done()
   if self.s
   then
      self.s:close()
      self.s = nil
   end
   self:clear_ev()
end

function skv:fail(s)
   self.error = s
   if self.debug
   then
      error(s)
   end
end

-- Client code

function skv:init_client()
   self.listen_timeout = INITIAL_LISTEN_TIMEOUT
   self.fsm:Initialized()
end

function skv:is_long_lived()
   return self.long_lived
end

function skv:connect()
   local s = socket.tcp()
   s:settimeout(0)
   r, e = s:connect(self.host, self.port)
   self.s = s
   if r == 1
   then
      self.fsm:Connected()
   else
      local fd = s:getfd()
      self.s_w = ev.IO.new(function (loop, io, revents)
                              r, e = s:connect(self.host, self.port)
                              if self.debug then 
                                 print('!!w!!', r, e) end
                              if e == ERR_CONNECTION_REFUSED
                              then
                                 self.fsm:ConnectFailed()
                                 return
                              end
                              self.fsm:Connected()
                           end, fd, ev.WRITE)
      self.s_t = ev.Timer.new(function (loop, o, revents)
                                 if self.debug then 
                                    print '!!t1!!' end
                                 self.fsm:ConnectFailed()
                              end, CONNECT_TIMEOUT)
      self.s_t:start(self.loop)
      self.s_w:start(self.loop)
   end
end

function skv:clear_ev()
   -- kill listeners, if any
   local c = 0
   if self.debug then print 'clear_ev' end
   for _, e in ipairs({"s_w", "s_t", "s_r"})
   do
      if self[e]
      then
         if self.debug then print(' removing', e, self[e]) end
         o = self[e]
         o:stop(self.loop)
         self[e] = nil
         c = c + 1
      end
   end
end

function skv:send_local_updates()
end

function skv:send_listeners()
end

function skv:set_read_handler()
   local fd = self.s:getfd()
   self.s_r = ev.IO.new(function (loop, io, revents)
                           r, e = self.s:receive()
                           --print('client-read', r, e)
                           if r
                           then
                              -- XXX - do something
                           else
                              self.fsm:ConnectionClosed()
                           end
                        end, fd, ev.READ)
   self.s_r:start(self.loop)
   
end

-- Server code

function skv:init_server()
   self.fsm:Initialized()
   self.connections = {}
end

function skv:bind()
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   r, err = s:bind(self.host, self.port)
   if r
   then
      self.s = s
      self.fsm:Bound()
      return
   else
      self.fsm:BindFailed()
   end
end

function skv:start_wait_connections()
   self.s:listen(10)
   local fd = self.s:getfd()
   self.s_r = ev.IO.new(function (loop, o, revents)
                           if self.debug then print(' --accept--') end
                           local c = self.s:accept()
                           if self.debug then print(' --accept--', c) end
                           if c ~= nil
                           then
                              self:new_client(c)
                           end
                        end, fd, ev.READ)
   self.s_r:start(self.loop)
end

function skv:new_client(c)
   skvclient:new{c=c, parent=self}
end

function skv:increase_retry_timer()
   -- 1.5x every time.. should eventually behave reasonably
   self.listen_timeout = self.listen_timeout * 3 / 2
end

function skv:start_retry_timer()
   self.s_t = ev.Timer.new(function (loop, o, revents)
                              if self.debug then 
                                 print '!!t2!!' end
                              self:clear_ev()
                              self.fsm:Timeout()
                           end, CONNECT_TIMEOUT):start(self.loop)
end

-- Server's single client side connection handling

skvclient.__index = skvclient

function skvclient:new(o)
   local o = o or {}
   check_parameters("skvclient:new", o, {"c", "parent"})
   setmetatable(o, self)
   o.parent.connections[o] = 1
   return o
end

function skvclient:done()
   assert(self.parent.connections[self] ~= nil)
   self.parent.connections[self] = nil
   self.c:close()
end

return skv
