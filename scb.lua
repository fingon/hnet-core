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
-- Last modified: Tue Apr 30 13:01:37 2013 mstenber
-- Edit time:     202 min
--

-- convenience stuff on top of LuaSocket (most of the action happens
-- in scbtcp.lua and scpudp.lua)
--
-- it _used_ to be on top of lua-ev, but debuggability was bad =>
-- moved to ssloop

local mst = require 'mst'
local ssloop = require 'ssloop'
local socket = require 'socket'
local ipv4s = require 'ipv4s'
local type = type
local string = require 'string'

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

local support_ipv6
if socket.tcp6 and socket.udp
then
   LOCALHOST='::1'
   support_ipv6=true
else
   LOCALHOST='127.0.0.1'
end

-- wrap udp socket in Scb structure, and set it up with the given
-- callback
function wrap_udp_socket(d)
   mst.check_parameters("scb:wrap_socket", d, {"s", "callback"}, 3)
   local s = d.s
   s:settimeout(0)
   d.listen_read = true
   d.listen_write = false
   function d:handle_io_read ()
      local r, ip, port = self.s:receivefrom()
      self:a(r, 'timeout should not happen, we are non-blocking after all')
      self:a(type(r) == 'string', 'non-string result from receivefrom', r, ip, port)
      self.callback(r, ip, port)
   end
   local o = Scb:new(d)
   o:start()
   return o
end

function parameters_or_host_ipv6ish(d)
   -- check explicit parameters
   if d.ipv4 or not support_ipv6
   then
      return false
   end
   if d.ipv6 or d.v6only
   then
      return true
   end
   -- by default we're ipv6-ish; however, if this looks like ipv4
   -- address, it isn't
   if d.host
   then
      local r = ipv4s.address_to_binary_address(d.host)
      if r
      then
         return false
      end
   end
   return true
end

function create_udp_socket(d)
   mst.check_parameters("scb:create_udp_socket", d, 
                        {"host", "port"}, 3)
   local s
   -- should we?
   if parameters_or_host_ipv6ish(d)
   then
      s = socket.udp6()
      if d.v6only
      then
         local r, err = s:setoption('ipv6-v6only', true, 'setting ipv6-only')
         mst.a(r, err)
      end
   else 
      -- normal socket? v4/v6 decision is painful here though, but
      -- guess we don't really want IPv4 anyway..
      s = socket.udp()
   end
   s:settimeout(0)
   s:setoption('reuseaddr', true)
   --s:setoption('reuseportr', true)
   local r, err = s:setsockname(d.host, d.port)
   if not r
   then
      return r, string.format('error in setsockname:%s for %s',
                              err, mst.repr(d))
   end
   return s
end

-- set up new udp socket, with given host, port, and calling the given
-- callback whenever applicable
function new_udp_socket(d)
   mst.check_parameters("scb:new_udp_socket", d, 
                        {"host", "port", "callback"}, 3)
   local s = create_udp_socket(d)
   local o = wrap_udp_socket{s=s, callback=d.callback}
   return o
end
