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
-- Last modified: Wed Sep 19 17:20:31 2012 mstenber
-- Edit time:     131 min
--

require "socket"
require 'mst'
require 'evwrap'
local ev = require 'ev'

-- SMC-generated state machine
local sm = require 'skv_sm'

module(..., package.seeall)

skv = mst.create_class{mandatory={"loop", "long_lived"}}
skvclient = mst.create_class{mandatory={"s", "parent"}}

-- first, skv

skv.__index = skv

local HOST = '127.0.0.1'
local PORT = 12345
local CONNECT_TIMEOUT = 0.1
local INITIAL_LISTEN_TIMEOUT = 0.2

local ERR_CONNECTION_REFUSED = "connection refused"

function skv:init()
   self.host = self.host or HOST
   self.port = self.port or PORT
   if self.debug
   then
      --local f = iself.open('x.log', 'w')
      self.fsm = sm:new({owner=self, debugFlag=true})
   else
      self.fsm = sm:new({owner=self})
   end
   self.fsm:enterStartState()
end

-- we're done with the object -> clear state
function skv:done()
   if self.s
   then
      self.s:done()
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
   self.connected = false
   self.s = evwrap.new_connect{host=self.host, port=self.port,
                               callback=function (c) 
                                  if c
                                  then
                                     self.connected = true
                                     self.s = s
                                     s.callback = function (r)
                                        self:handle_read(r)
                                     end
                                     s.close_callback = function (s)
                                        self.fsm:ConnectionClosed()
                                     end
                                     self.fsm:Connected()
                                  else
                                     self.fsm:ConnectFailed()
                                  end
                               end}
   if not self.connected
   then
      self.s_t = ev.Timer.new(function (loop, o, revents)
                                 if self.debug then 
                                    print '!!t1!!' end
                                 self.fsm:ConnectFailed()
                              end, CONNECT_TIMEOUT)
      self.s_t:start(self.loop)
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

function skv:handle_read(r)
   assert(r and #r)
   -- XXX - do something
end

function skv:set_read_handler()
   -- nop?
end

-- Server code

function skv:init_server()
   self.fsm:Initialized()
   self.connections = {}
end

function skv:bind()
   s, err = evwrap.new_listener{host=self.host, port=self.port, 
                                callback=function (c) 
                                   self:new_client(c)
                                end}
   if s
   then
      self.s = s
      self.fsm:Bound()
      return
   else
      self.fsm:BindFailed()
   end
end

function skv:new_client(s)
   skvclient:new{s=s, parent=self}
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

function skvclient:init()
   self.parent.connections[self] = 1
   self.s.callback = function (s) self.handle_read(s) end
   self.s.done_callback = function (s) self.handle_close() end
end

function handle_read(s)
   -- to do
end

function handle_close()
   self:done()
end

function skvclient:done()
   assert(self.parent.connections[self] ~= nil)
   self.parent.connections[self] = nil
   self.s:done()
end
