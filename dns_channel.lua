#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_channel.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Apr 30 17:02:57 2013 mstenber
-- Last modified: Tue Apr 30 17:52:19 2013 mstenber
-- Edit time:     14 min
--

-- DNS channels is an abstraction between two entities that speak DNS,
-- with just possibly one of them known ('us'). send_msg and receive_msg
-- do the obvious, with optional extra argument for src/dst (in case
-- of UDP channel).

-- All are set up with get_udp_channel(d), get_tcp_channel_socket(d)
-- or get_tcp_channel_connect(d).

require 'mst'
require 'scr'
require 'scb'
require 'scbtcp'
require 'dns_const'

module(..., package.seeall)

channel = mst.create_class{class='channel', mandatory={'s'}}

function channel:init()
   self:d('init')
   self.s = scr.wrap_socket(self.s)
end

function channel:uninit()
   self:d('uninit')
   -- explicitly close the socket (assume we always have one)
   self.s:done()
end

udp_channel = channel:new_subclass{class='udp_channel'}

function udp_channel:send_msg(msg, dst)
   self:a(msg, 'no message')
   self:a(dst, 'no destination')

   local host, port = unpack(dst)
   self:a(host and port, 'host or port missing', dst)

   local binary = dns_codec.dns_message:encode(msg)

   self.s:sendto(binary, host, port)
end

function udp_channel:receive_msg(timeout)
   local b, ip, port = self.s:receivefrom(timeout)
   if not b then return nil end
   local msg, err = dns_codec.dns_message:decode(b)
   -- if successful, return msg, src
   if msg
   then
      return msg, {ip, port}
   end
   -- otherwise return nil, err
   return nil, err
end

function get_udp_channel(self)
   self = self or {}
   local udp_port = self.port or dns_const.PORT 
   mst.d('creating udp socket', self)
   local udp_s, err = scb.create_udp_socket{host='*', port=udp_port}
   mst.a(udp_s, 'unable to create udp socket', err)
   return udp_channel:new{s=udp_s}
end
