#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: evwrap.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Sep 19 15:10:18 2012 mstenber
-- Last modified: Wed Sep 19 16:37:45 2012 mstenber
-- Edit time:     49 min
--

-- convenience stuff on top of ev
--
-- coroutine-driven LuaSocket wrapper
-- 
-- there's write() call which queues things internally
--
-- for reading, the output is provided to the 'callback' given to it
--
-- also, the socket to be wrapped has to be given as 's'
-- and the event loop to use as 'loop' (optional)

local mst = require 'mst'
local ev = require 'ev'

module(..., package.seeall)

--- EVWrapBase (used to wrap both listening, connecting and r&w sockets)

local EVWrapBase = mst.create_class{required={"s"}}

function EVWrapBase:init()
   -- make sure the socket is indeed nonblocking
   self.s.settimeout(0)

   -- set up the event loop related things
   self.loop = self.loop or ev.Loop.default

   if self.listen_write
   then
      self.s_w = ev.IO.new(function (loop, io, revents)
                              assert(loop == self.loop)
                              self:handle_io_write()
                           end, fd, ev.WRITE)
      -- write queue
      self.wq = {}

   end

   if self.listen_read
   then
      self.s_r = ev.IO.new(function (loop, io, revents)
                              assert(loop == self.loop)
                              self:handle_io_read()
                           end, fd, ev.READ)
      -- writer we start only if there's need; reading starts
      -- implicitly as soon as we're initialized, which is .. now.
      self.s_r.start(self.loop)
   end

end

function EVWrapBase:start()
   self.s_r:start()
   self.s_w:start()
end

function EVWrapBase:stop()
   self.s_r:stop()
   self.s_w:stop()

end


function EVWrapBase:done()
   -- initially just stop the handlers
   self:stop()

   -- call done callback (if any)
   if self.done_callback
   then
      self.done_callback(self)
   end

   if self.s
   then
      self.s.close()
      self.s = nil
   end
   self.s_r = nil
   self.s_w = nil
end

--- EVWrapIO (used for connecting + listen->accepted)

EVWrapIO = EVWrapBase:new{listen_read=true, listen_write=true}

function EVWrapIO:handle_io_read()
   r, error, partial = self.s:receive()
   s = r or partial
   if not s or #s == 0
   then
      assert(error == "closed")
      if self.close_callback
      then
         self.close_callback(self)
      end
      self:done()
   else
      self.callback(s)
   end
end

function EVWrapIO:handle_io_write()
   -- it's writable.. nothing in the queue?
   if #self.wq == 0
   then
      self.s_w.stop()
      return
   end
   
   -- we have _something_. let's try to write the first one..
   s, i = self.wq[1]
   i = i or 1
   r, err = self.s:send(s, i)

   -- todo - handle writing errors here

   -- fallback
   assert(r, err)
   
   -- update the queue
   if r == #s
   then
      table.remove(self.wq, 1)
      return
   end
   
   -- r can't be >#s, or we have oddity on our hands
   assert(r<#s)

   -- just wait for the next writable callback
   self.wq[1] = {s, r+1}
end

function EVWrapIO:write(s)
   table.insert(self.wq, s)
   self.s_w.start()
end

--- EVWrapListen

local EVWrapListen = EVWrapBase:new{listen_read=true, listen_write=false}

function EVWrapListen:handle_io_read()
   if self.debug then print(' --accept--') end
   local c = self.s:accept()
   if self.debug then print(' --accept--', c) end
   assert(self.callback)
   if c 
   then
      evw = EVWrapIO:new{s=c}
      self.callback(evw)
   end
end

--- EVWrapConnect

local EVWrapConnect = EVWrapBase:new{listen_write=true}

function EVWrapConnect:init()
   -- stop the client - first connection has to go through for the i/o
   -- to have any meaning
   self.evio:stop()

   -- superclass init
   EVWrapBase.init(self)
end

function EVWrapConnect:handle_io_write()
   r, err = s:connect(self.host, self.port)
   if self.debug then 
      print('!!w!!', r, e) end
   assert(self.callback, 'missing callback from EVWrapConnect')
   if err == ERR_CONNECTION_REFUSED
   then
      self.callback(nil, err)
      return
   end
   self.evio:start()
   self.callback(self.evio)

   -- make sure we don't close the socket when we die 
   self.s = nil
   self:done()
end

-- proxy the 'new'

function new(...)
   return EVWrap:new(...)
end

function wrap_socket(s, callback)
   evio = EVWrapIO:new{s=s, callback=callback}
   return evio
end

function new_listener(host, port, callback)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   r, err = s:bind(self.host, self.port)
   if r
   then
      s:listen(10)
      e = EVWrapListen:new{s=s, callback=callback}
      return e
   end
   return r, err
end

function new_connect(host, port, connected_callback, callback)
   local s = socket.tcp()
   s:settimeout(0)
   r, e = s:connect(host, port)
   evio = wrap_socket(s, callback)
   if r == 1
   then
      connected_callback(evio)
      return evio
   end
   -- apparently connect is still pending. create connect
   evwc = EVWrapConnect:new{s=s, 
                            host=host, port=port, evio=evio, 
                            callback=connected_callback}
   return evwc
end
