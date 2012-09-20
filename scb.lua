#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scb.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Sep 19 15:10:18 2012 mstenber
-- Last modified: Thu Sep 20 12:24:00 2012 mstenber
-- Edit time:     111 min
--

-- convenience stuff on top of LuaSocket
--
-- it _used_ to be on top of lua-ev, but debuggability was bad =>
-- moved to ssloop
--
-- there's write() call which queues things internally
--
-- for reading, the output is provided to the 'callback' given to it
--
-- also, the socket to be wrapped has to be given as 's'
-- and the event loop to use as 'loop' (optional)

require 'mst'
require 'ssloop'
require 'socket'

local ERR_CONNECTION_REFUSED = "connection refused"
local ERR_TIMEOUT = 'timeout'

module(..., package.seeall)

--- EVWrapBase (used to wrap both listening, connecting and r&w sockets)

local EVWrapBase = mst.create_class{required={"s"}, class="EVWrapBase"}

function EVWrapBase:init()
   self:d('init')
   -- make sure the socket is indeed nonblocking
   --self.s.settimeout(0)
   local l = ssloop.loop()

   if self.listen_write
   then
      self.s_w = l:new_writer(self.s, function () self:handle_io_write() end)
      -- write queue
      self.wq = {}
   end

   if self.listen_read
   then
      self:d('registering for read', fd)
      self.s_r = l:new_reader(self.s, function () self:handle_io_read() end)
      -- writer we start only if there's need; reading starts
      -- implicitly as soon as we're initialized, which is .. now.
      self.s_r:start()
   end

end

function EVWrapBase:repr()
   local fd = self.s:getfd()
   return string.format("fd:%d", fd)
end

function EVWrapBase:start()
   if self.listen_read
   then
      self.s_r:start()
   end
   if self.listen_write
   then
      self.s_w:start()
   end
end

function EVWrapBase:stop()
   if self.listen_read
   then
      self.s_r:stop()
   end
   if self.listen_write
   then
      self.s_w:stop()
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

EVWrapIO = EVWrapBase:new_subclass{listen_read=true, listen_write=true, 
                                   class="EVWrapIO"}

function EVWrapIO:handle_io_read()
   r, error, partial = self.s:receive()
   s = r or partial
   if not s or #s == 0
   then
      self:d('got read', s, #s, error)
      if error == 'closed'
      then
         -- ?
      else
         -- ??
      end
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
   while true
   do

      -- it's writable.. nothing in the queue?
      if #self.wq == 0
      then
         self:d("handle_io_write - queue empty")
         self.s_w:stop()
         self:d('done write-stop')
         return
      end
      
      -- we have _something_. let's try to write the first one..
      self:d("handle_io_write - sending")
      s, i = self.wq[1]
      i = i or 1
      r, err = self.s:send(s, i)

      self:d("handle_io_write - send done", r, err)

      -- todo - handle writing errors here

      -- fallback
      assert(r, err)
      
      -- update the queue
      if r == #s
      then
         self:d("handle_io_write removing from queue")
         table.remove(self.wq, 1)
      else
         -- r can't be >#s, or we have oddity on our hands
         assert(r<#s, "too many bytes written")

         -- just wait for the next writable callback
         self.wq[1] = {s, r+1}
         return
      end
      
   end
end

function EVWrapIO:write(s)
   table.insert(self.wq, s)
   self.s_w:start()
end

--- EVWrapListen

local EVWrapListen = EVWrapBase:new_subclass{listen_read=true, listen_write=false, class="EVWrapListen"}

function EVWrapListen:handle_io_read()
   self:d(' --accept--')
   local c = self.s:accept()
   self:d(' --accept--', c, c:getfd())
   self:a(self.callback, "no callback in handle_io_read")
   if c 
   then
      evio = EVWrapIO:new{s=c}
      self.callback(evio)
      assert(evio.listen_read)
      assert(evio.listen_write)
   end
end

--- EVWrapConnect

local EVWrapConnect = EVWrapBase:new_subclass{listen_write=true, class="EVWrapConnect"}

function EVWrapConnect:init()
   -- superclass init
   EVWrapBase.init(self)

   -- this is magic writer, it's on without any bytes to write
   -- (and triggers only once)
   self.s_w:start()
   
end

function EVWrapConnect:handle_io_write()
   self:d('handle_io_write')
   r, err = self.s:connect(self.host, self.port)
   self:d('!!w!!', r, e)
   assert(self.callback, 'missing callback from EVWrapConnect')
   if err == ERR_CONNECTION_REFUSED
   then
      self.callback(nil, err)
      return
   end

   if err == ERR_TIMEOUT
   then
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
   mst.check_parameters("scb:wrap_socket", d, {"s"}, 3)
   evio = EVWrapIO:new(d)
   assert(evio.listen_read)
   assert(evio.listen_write)
   return evio
end

function new_listener(d)
   mst.check_parameters("scb:new_listener", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   s:setoption('tcp-nodelay', true)
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
   mst.check_parameters("scb:new_connect", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('tcp-nodelay', true)
   r, e = s:connect(d.host, d.port)
   --print('new_connect', r, e)
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
