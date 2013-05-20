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
-- Last modified: Mon May 20 13:30:33 2013 mstenber
-- Edit time:     97 min
--

-- DNS channels is an abstraction between two entities that speak DNS,
-- with just possibly one of them known ('us'). send_msg and receive_msg
-- do the obvious, with optional extra argument for src/dst (in case
-- of UDP channel).

-- All are set up with get_udp_channel(d), get_tcp_channel_socket(d)
-- or get_tcp_channel_connect(d).

-- There's also convenience wrapper for doing resolution:

-- All clients need to do is just call
--
-- dns_channel.resolve_{q,msg}_{tcp,udp}(dns_server_ip, query_rr[,
-- timeout]) and Bob's your uncle - result will (appear to be)
-- synchronous returning of the dns_message received from remote end,
-- or nil, if timeout occurred.


require 'mst'
require 'scr'
require 'scb'
require 'scbtcp'
require 'dns_const'
require 'dns_codec'

ERR_TIMEOUT='timeout'

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

tcp_channel = channel:new_subclass{class='tcp_channel'}

function tcp_channel:send_binary(binary, timeout)
   self:a(binary, 'no binary')
   return self.s:send(binary, timeout)
end

function tcp_channel:send_msg(msg, timeout)
   self:a(msg, 'no message')
   local binary = dns_codec.dns_message:encode(msg)
   return self:send_binary(binary, timeout)
end

function tcp_channel:receive_msg(timeout)
   -- this is rather tricky. we have to ensure that we get only whole
   -- message, but we _also_ have to keep some leftovers around.
   
   while true
   do
      -- first off, see if we've got enough in our incoming queue
      if self.queue
      then
         local msg, pos = dns_codec.dns_message:decode(self.queue)
         if msg
         then
            self.queue = string.sub(self.queue, pos)
            return msg
         end
      end

      -- no (full?) message, have to receive more
      local b, err = self.s:receive(timeout)
      if not b
      then
         return nil, err
      end
      
      if self.queue
      then
         -- add to queue
         self.queue = self.queue .. b
      else
         -- new queue
         self.queue = b
      end
   end
end



udp_channel = channel:new_subclass{class='udp_channel'}

function udp_channel:send_binary(binary, dst)
   self:a(binary, 'no binary')
   self:a(dst, 'no destination')

   -- sanity check that ip + port also looks sane
   local ip, port = unpack(dst)
   port = port or dns_const.PORT
   self:a(ip and port, 'ip or port missing', dst)

   return self.s:sendto(binary, ip, port)
end

function udp_channel:send_msg(msg, dst)
   self:a(msg, 'no message')
   local binary = dns_codec.dns_message:encode(msg)
   return self:send_binary(binary, dst)
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

--- public api

-- raw channel creation

function get_udp_channel(self)
   self = self or {}
   local ip = self.ip or '*'
   local port = self.port or dns_const.PORT 
   mst.d('creating udp socket', self)
   local udp_s, err = scb.create_udp_socket{ip=ip, port=port}
   mst.a(udp_s, 'unable to create udp socket', err)
   return udp_channel:new{s=udp_s}
end

function get_tcp_channel(self)
   self = self or {}
   local ip = self.ip or '*'
   local port = self.port or dns_const.PORT
   mst.d('creating tcp socket', self)
   mst.a(self.server)
   local tcp_s, err = scbtcp.create_socket{ip=ip, port=port}
   mst.a(tcp_s, 'unable to create tcp socket', tcp_port, err)
   local c = tcp_channel:new{s=tcp_s}
   local server_port = self.server_port or dns_const.PORT
   local r, err = c.s:connect(self.server, server_port)
   if not r
   then
      return nil, err
   end
   return c
end

-- convenience 'resolve' functions

function resolve_msg_udp(server, msg, timeout)
   mst.a(server, 'server mandatory')
   mst.a(msg and msg.h and msg.h.id, 'msg with id mandatory', msg)
   local c, err = get_udp_channel{ip='*', port=0}
   if not c then return c, err end
   local dst = {server, dns_const.PORT}
   local r, err = c:send_msg(msg, dst, timeout)
   if not r then return nil, err end
   while true
   do
      local got, err = c:receive_msg(timeout)
      if not got then return nil, err end
      local ip, port = unpack(err)
      -- if not, it's bogon
      if ip == server and got.h and got.h.id == msg.h.id
      then
         -- XXX - should we call done on this or not?
         c:done()
         return got
      else
         mst.d('invalid reply', ip, port, got)
      end
   end
end

function resolve_msg_tcp(server, msg, timeout)
   mst.a(server and msg, 'server+msg not provided')
   local c = get_tcp_channel{ip='*', port=0, server=server}
   if not c then return c, err end
   local r, err = c:send_msg(msg, timeout)
   if not r then return nil, err end
   local got = c:receive_msg(timeout)
   c:done()
   if not got then return nil, ERR_TIMEOUT end
   return got
end

function resolve_q_base(server, q, timeout, resolve_msg)
   -- 16-bit id, 0 = reserved
   local sid = mst.randint(1, 65535)
   mst.a(sid, 'unable to create id')

   local msg, err = resolve_msg(server, {qd={q}, h={rd=true, id=sid}}, timeout)
   if not msg
   then
      return nil, err
   end
   if msg.h.id ~= sid
   then
      return nil, 'invalid reply' .. mst.repr{sid, msg}
   end
   return msg
end

function resolve_q_udp(server, q, timeout)
   return resolve_q_base(server, q, timeout, resolve_msg_udp)
end

function resolve_q_tcp(server, q, timeout)
   return resolve_q_base(server, q, timeout, resolve_msg_tcp)
end

function resolve_q(server, q, timeout)
   local msg, err = resolve_q_udp(server, q, timeout)
   if msg and msg.h.tc
   then
      local msg2, err2 = resolve_q_tcp(server, q, timeout)
      return msg2 or msg, err2
   end
   return msg, err
end
