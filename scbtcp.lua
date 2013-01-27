#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scbtcp.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Sun Jan 27 11:15:32 2013 mstenber
-- Last modified: Sun Jan 27 11:25:08 2013 mstenber
-- Edit time:     5 min
--

-- TCP code related to simple callback stuff (scb)

local scb = require 'scb'
local mst = require 'mst'
local socket = require 'socket'

local ERR_CONNECTION_REFUSED = "connection refused"
local ERR_TIMEOUT = 'timeout'

module(...)

local _base = scb.Scb

--- ScbIO (used for connecting + listen->accepted)

ScbIO = _base:new_subclass{listen_read=true, listen_write=true, 
                                   class="ScbIO"}

function ScbIO:init()
   -- write queue
   self.wq = mst.array:new{}

   -- the rest is up to baseclass..
   _base.init(self)
end

function ScbIO:handle_io_read()
   self:d('handle_io_read')
   local r, error, partial = self.s:receive(2^10)
   local s = r or partial
   if not s or #s == 0
   then
      self:d('got read', s, #s, error)
      if error == 'closed'
      then
         -- ?
      else
         -- ??
      end
      self:call_callback_once('close_callback')
      self:done()
   else
      self.callback(s)
   end
end

function ScbIO:handle_io_write()
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
      local s, i = self.wq[1]
      i = i or 1
      local r, err = self.s:send(s, i)

      self:d("handle_io_write - send done", r, err)

      -- todo - handle writing errors here

      if not r and err == 'closed'
      then
         self:call_callback_once('close_callback')
         self:done()
         return
      end

      -- fallback
      self:a(r, err)
      
      -- update the queue
      if r == #s
      then
         self:d("handle_io_write removing from queue")
         self.wq:remove_index(1)
      else
         -- r can't be >#s, or we have oddity on our hands
         self:a(r<#s, "too many bytes written")

         -- just wait for the next writable callback
         self.wq[1] = {s, r+1}
         return
      end
      
   end
end

function ScbIO:write(s)
   self:d('write', #s)
   self.wq:insert(s)
   self.s_w:start()
end

--- ScbListen

local ScbListen = _base:new_subclass{listen_read=true, listen_write=false, class="ScbListen"}

function ScbListen:handle_io_read()
   self:d(' --accept--')
   local c = self.s:accept()
   self:d(' --accept--', c, c:getfd())
   self:a(self.callback, "no callback in handle_io_read")
   if c 
   then
      c:settimeout(0)
      evio = ScbIO:new{s=c, p=self}
      self:a(evio.listen_read, 'listen_read disappeared')
      self:a(evio.listen_write, 'listen_write disappeared')
      evio:start()
      self.callback(evio)
   end
end

--- ScbConnect

local ScbConnect = _base:new_subclass{listen_write=true, class="ScbConnect"}

function ScbConnect:handle_io_write()
   self:d('handle_io_write')
   local r, err = self.s:connect(self.host, self.port)
   self:d('connect result', r, err)
   self:a(self.callback, 'missing callback from ScbConnect')
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
   self:stop()

   -- then, forward the freshly wrapped IO socket onward
   -- (someone needs to set up callback(s))
   evio = wrap_socket(self.evio_d)
   self.callback(evio)

   -- we're ready to be cleaned (as if we were anywhere anyway, after :stop())
   self.s = nil
   self:done()
end

function wrap_socket(d)
   mst.check_parameters("scb:wrap_socket", d, {"s"}, 3)
   local s = d.s
   s:settimeout(0)
   evio = ScbIO:new(d)
   mst.a(evio.listen_read and evio.listen_write)
   evio:start()
   return evio
end

function new_listener(d)
   mst.check_parameters("scb:new_listener", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   s:setoption('tcp-nodelay', true)
   local r, err = s:bind(d.host, d.port)
   if r
   then
      s:listen(10)
      d.s = s
      l = ScbListen:new(d)
      l:start()
      return l
   end
   return nil, err
end

function new_connect(d)
   -- host, port, connected_callback, callback
   mst.check_parameters("scb:new_connect", d, {"host", "port", "callback"}, 3)
   local s = socket.tcp()
   s:settimeout(0)
   s:setoption('tcp-nodelay', true)
   local r, e = s:connect(d.host, d.port)
   --print('new_connect', r, e)
   d.s = s
   if r == 1
   then
      evio = wrap_socket(d)
      connected_callback(evio)
      return evio
   end
   -- apparently connect is still pending. create connect
   d.evio_d = mst.table_copy(d)
   c = ScbConnect:new(d)
   c:start()
   return c
end
