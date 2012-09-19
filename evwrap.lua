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
-- Last modified: Wed Sep 19 17:48:10 2012 mstenber
-- Edit time:     81 min
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

local EVWrapBase = mst.create_class{required={"s"}, debug=true, class="EVWrapBase"}

function EVWrapBase:init()
   self.d('init')
   -- make sure the socket is indeed nonblocking
   --self.s.settimeout(0)

   -- set up the event loop related things
   self.loop = self.loop or ev.Loop.default

   local fd = self.s:getfd()

   if self.listen_write
   then
      self.d('registering for write', fd)
      self.s_w = ev.IO.new(function (loop, io, revents)
                              assert(loop == self.loop)
                              self.d('--got write--', fd)
                              self:handle_io_write()
                           end, fd, ev.WRITE)
      -- write queue
      self.wq = {}

   end

   if self.listen_read
   then
      self.d('registering for read', fd)
      self.s_r = ev.IO.new(function (loop, io, revents)
                              assert(loop == self.loop)
                              self.d('--got read--', fd)
                              self:handle_io_read()
                           end, fd, ev.READ)
      -- writer we start only if there's need; reading starts
      -- implicitly as soon as we're initialized, which is .. now.
      self.s_r:start(self.loop)
   end

end

function EVWrapBase:repr()
   local fd = self.s:getfd()
   return string.format("fd:%d", fd)
end

function EVWrapBase:start()
   if self.listen_read
   then
      self.s_r:start(self.loop)
   end
   if self.listen_write
   then
      self.s_w:start(self.loop)
   end
end

function EVWrapBase:stop()
   if self.listen_read
   then
      self.s_r:stop(self.loop)
   end
   if self.listen_write
   then
      self.s_w:stop(self.loop)
   end
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
      self.s:close()
      self.s = nil
   end
   self.s_r = nil
   self.s_w = nil
end

--- EVWrapIO (used for connecting + listen->accepted)

EVWrapIO = EVWrapBase:new_subclass{listen_read=true, listen_write=true, class="EVWrapIO"}

function EVWrapIO:handle_io_read()
   r, error, partial = self.s:receive()
   s = r or partial
   if not s or #s == 0
   then
      assert(error == "closed", "got error " .. error .. " from " .. tostring(self))
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

local EVWrapListen = EVWrapBase:new_subclass{listen_read=true, listen_write=false, class="EVWrapListen"}

function EVWrapListen:handle_io_read()
   self.d(' --accept--')
   local c = self.s:accept()
   self.d(' --accept--', c)
   assert(self.callback)
   if c 
   then
      evw = EVWrapIO:new{s=c}
      self.callback(evw)
   end
end

--- EVWrapConnect

local EVWrapConnect = EVWrapBase:new_subclass{listen_write=true, class="EVWrapConnect"}

function EVWrapConnect:init()
   -- superclass init
   EVWrapBase.init(self)

   -- this is magic writer, it's on without any bytes to write
   -- (and triggers only once)
   self.s_w:start(self.loop)
end

function EVWrapConnect:handle_io_write()
   r, err = self.s:connect(self.host, self.port)
   self.d('!!w!!', r, e)
   assert(self.callback, 'missing callback from EVWrapConnect')
   if err == ERR_CONNECTION_REFUSED
   then
      self.callback(nil, err)
      return
   end

   -- first off, we're done! so get rid of the filehandle + mark us done
   self.s = nil
   self:done()

   -- then, forward the freshly wrapped IO socket onward
   -- (someone needs to set up callback(s))
   evio = wrap_socket(self.evio_d)
   self.callback(evio)
end

-- proxy the 'new'

function new(...)
   return EVWrap:new(...)
end

function wrap_socket(d)
   mst.check_parameters("evwrap:wrap_socket", d, {"s"}, 3)
   evio = EVWrapIO:new(d)
   return evio
end

function new_listener(d)
   mst.check_parameters("evwrap:new_listener", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   r, err = s:bind(d.host, d.port)
   if r
   then
      s:listen(10)
      d.s = s
      e = EVWrapListen:new(d)
      return e
   end
   return r, err
end

function new_connect(d)
   -- host, port, connected_callback, callback
   mst.check_parameters("evwrap:new_connect", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   r, e = s:connect(d.host, d.port)
   d.s = s
   if r == 1
   then
      evio = wrap_socket(d)
      connected_callback(evio)
      return evio
   end
   -- apparently connect is still pending. create connect
   d.evio_d = mst.copy_table(d)
   evwc = EVWrapConnect:new(d)
   return evwc
end
