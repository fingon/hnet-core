#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scb.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Sep 19 15:10:18 2012 mstenber
-- Last modified: Sun Jan 27 11:23:36 2013 mstenber
-- Edit time:     164 min
--

-- convenience stuff on top of LuaSocket (most of the action happens
-- in scbtcp.lua and scpudp.lua)
--
-- it _used_ to be on top of lua-ev, but debuggability was bad =>
-- moved to ssloop

local mst = require 'mst'
local ssloop = require 'ssloop'

module(...)

--- Scb (used to wrap both listening, connecting and r&w sockets)

-- the socket to be wrapped has to be given as 's'
Scb = mst.create_class{required={"s"}, class="Scb"}

function Scb:init()
   self:d('init')
   -- make sure the socket is indeed nonblocking
   --self.s.settimeout(0)
   local l = ssloop.loop()

   if self.listen_write
   then
      self.s_w = l:new_writer(self.s, function () 
                                 self:d('write callback')
                                 self:handle_io_write() end, self)
   end

   if self.listen_read
   then
      local fd = self.s:getfd()
      self:d('registering for read', fd)
      self.s_r = l:new_reader(self.s, function () 
                                 self:d('read callback')
                                 self:handle_io_read() end, self)
   end
end

function Scb:detach()
   self:stop()
   self.s = nil
end

function Scb:uninit()
   self:d('uninit')

   -- initially just stop the handlers
   self:stop()

   -- call done callback (if any)
   self:call_callback_once('done_callback')

   if self.s
   then
      self:d('closing', self.s)
      self.s:close()
      self.s = nil
   end
   self.s_r = nil
   self.s_w = nil
end

function Scb:repr_data()
   return mst.repr{s=self.s, p=self.p}
end

function Scb:start()
   if self.s_r
   then
      self.s_r:start()
   end
   if self.s_w
   then
      self.s_w:start()
   end
end

function Scb:stop()
   if self.s_r
   then
      self.s_r:stop()
   end
   if self.s_w
   then
      self.s_w:stop()
   end
end

