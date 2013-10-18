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
-- Last modified: Sat Oct 19 00:55:59 2013 mstenber
-- Edit time:     200 min
--

-- DNS channels is an abstraction between two entities that speak DNS,
-- with just possibly one of them known ('us'). send_msg and receive_msg
-- do the obvious, with optional extra argument for src/dst (in case
-- of UDP channel).

-- All are set up with get_udp_channel(d), get_tcp_channel(d).

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

-- this is a single message we have received (or are about to send).
-- it is mainly data structure, that we can use to pass instead of (a
-- number of) other alternatives.

-- notable members:

-- ip, port = where did we receive it from (if any)

-- (for internal use) msg, binary = encoded/raw representation of dns_message

-- accessors:

-- get_msg() - get readable message (_may_ fail if not decodeable
-- recursively)

-- get_binary() - get binary encoded message

msg = mst.create_class{class='msg'}

function msg:repr_data()
   return mst.repr{ip=self.ip,
                   port=self.port,
                   tcp=self.tcp,
                   binary=(self.binary and true or nil),
                   msg=self.msg,

                   -- we probably want to show full message;
                   -- otherwise debugging is hard.
                   -- alternative is to show if it's just present, like below
                   --self.msg and true or nil,
                  }
end

function msg:get_binary()
   if not self.binary
   then
      self:d('encoding to binary')
      self:a(self.msg, 'no msg either?!')
      local b, err = dns_codec.dns_message:encode(self.msg)
      self.binary = b
      return b, err
   end
   return self.binary
end

function msg:get_msg()
   if not self.msg
   then
      self:d('decoding from binary')
      self:a(self.binary, 'no binary')
      local r, err = dns_codec.dns_message:decode(self.binary)
      self.msg = r
      return r, err
   end
   return self.msg
end

function msg:resolve_udp(timeout)
   self:d('resolve_udp', timeout)
   local server = self.ip
   mst.a(server, 'server mandatory')
   local msg = self:get_msg()
   mst.a(msg and msg.h and msg.h.id, 'msg with id mandatory', msg)
   local c, err = get_udp_channel{ip='*', port=0, remote_ip=server}
   if not c then return c, err end
   local dst = {server, dns_const.PORT}
   local r, err = c:send(self, dst, timeout)
   if not r 
   then 
      self:d('send returned nil', err)
      return nil, err 
   end
   while true
   do
      self:d('waiting for reply')
      local got, err = c:receive(timeout)
      self:d('got reply', got, err)
      if not got then return nil, err end
      local ip, port = got.ip, got.port
      local msg2, err2 = got:get_msg()
      -- if not, it's bogon
      if ip == server and (not msg2 or (msg2.h and msg2.h.id == msg.h.id))
      then
         -- XXX - should we call done on this or not?
         c:done()
         return got
      else
         mst.d('invalid reply', ip, port, msg2)
      end
   end
end

function msg:resolve_tcp(timeout)
   self:d('resolve_tcp', timeout)
   local server = self.ip
   local msg = self:get_msg()
   mst.a(server and msg, 'server+msg not provided')
   -- just sanity check, we pass along really self
   self:d('getting a channel')
   local c, err = get_tcp_channel{ip='*', port=0, remote_ip=server}
   if not c then return c, err end
   self:d('sending request')
   local r, err = c:send(self, timeout)
   if not r then return nil, err end
   self:d('waiting for reply')
   local got, err = c:receive(timeout)
   c:done()
   self:d('got', got, err)
   if not got then return nil, err end
   return got
end


function msg:resolve(timeout)
   if self.tcp
   then
      return self:resolve_tcp(timeout)
   else
      return self:resolve_udp(timeout)
   end
end


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

function tcp_channel:send(o, timeout)
   self:a(o, 'no o')
   self:a(mst.get_class(o) == msg, 'invalid superclass', o)
   local b, err = o:get_binary()
   if not b then return nil, 'send error - unable to encode ' .. err end
   return self:socket_send(b, timeout)
end

function tcp_channel:socket_send(b, timeout)
   -- prefix the message with number of bytes in request (16 bits)
   return self.s:send(codec.u16_to_nb(#b) .. b, timeout)
end

local _decode_args = {disable_decode_names=true,
                      disable_decode_rrs=true}

function tcp_channel:receive(timeout)
   -- this is rather tricky. we have to ensure that we get only whole
   -- message, but we _also_ have to keep some leftovers around.
   
   while true
   do
      -- first off, see if we've got enough in our incoming queue
      -- (we _at least_ have to have the 16 bits for number of bytes)
      if self.queue and #self.queue >= 2
      then
         local q = self.queue
         local l = codec.nb_to_u16(q)
         if #q >= (l + 2)
         then
            local b = string.sub(q, 3, l+2)
            self.queue = string.sub(q, l+3)
            self:d('tcp payload with bytes', l)
            return msg:new{binary=b, tcp=true}
         else
            self:d('missing part of tcp payload - got/exp', #q, l+2)
         end
      end

      -- no (full?) message, have to receive more
      local b, err = self.s:receive(timeout)
      if not b
      then
         self:d('receive error', err)
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

function udp_channel:send(o)
   self:a(o, 'no o')
   self:a(mst.get_class(o) == msg, 'invalid superclass', o)

   -- sanity check that ip + port also looks sane
   local ip = o.ip 
   local port = o.port or dns_const.PORT
   self:a(ip and port, 'ip or port missing', o)

   local b, err = o:get_binary()
   if not b then return nil, 'send error - unable to encode ' .. err end
   
   -- RFC1035 (classic) mode limits length of message to 512 bytes.
   if b and #b > dns_const.MAXIMUM_PAYLOAD_SIZE
   then
      o.binary = nil

      local m = o.msg

      -- clear non-query sublists
      for i, v in ipairs(dns_codec.dns_message.lists)
      do
         local n, f = unpack(v)
         if n ~= 'qd'
         then
            self:d('truncating list', n)
            m[n] = {}
         end
      end

      -- set the truncated bit in the header
      local h = m.h or {}
      h.tc = true
      m.h = h
      
      b = o:get_binary()
      if #b > dns_const.MAXIMUM_PAYLOAD_SIZE
      then
         return nil, 'too long message even with truncation'
      end
   end
   return self:socket_sendto(b, ip, port)
end

function udp_channel:socket_sendto(b, ip, port)
   return self.s:sendto(b, ip, port)
end

function udp_channel:receive(timeout)
   local b, ip, port = self.s:receivefrom(timeout)
   if not b then return nil end
   local m, err = dns_codec.dns_message:decode(b, _decode_args)
   -- if successful, return msg, src
   if m
   then
      return msg:new{binary=b, ip=ip, port=port, tcp=false}
   end
   -- otherwise return nil, err
   return nil, err
end

--- public api

-- raw channel creation

function get_udp_channel(self)
   self = self or {}
   self.ip = self.ip or '*'
   self.port = self.port or dns_const.PORT 
   mst.d('creating udp socket [get_udp_channel]', self)
   local udp_s, err = scb.create_udp_socket(self)
   if not udp_s
   then
      return nil, 'unable to create udp socket ' .. mst.repr(err)
   end
   return udp_channel:new{s=udp_s}
end

function get_tcp_channel(self)
   self = self or {}
   local ip = self.ip or '*'
   local port = self.port or dns_const.PORT
   mst.a(self.remote_ip)
   local tcp_s, err = scbtcp.create_socket{ip=ip, port=port}
   mst.a(tcp_s, 'unable to create tcp socket', port, err)
   local c = tcp_channel:new{s=tcp_s}
   local remote_port = self.remote_port or dns_const.PORT
   local r, err = c.s:connect(self.remote_ip, remote_port)
   if not r
   then
      return nil, err
   end
   return c
end

-- convenience 'resolve' functions

function resolve_msg_udp(server, m, timeout)
   mst.a(server, 'server mandatory')
   mst.a(m and m.h and m.h.id, 'msg without mandatory id', m)
   local cmsg = msg:new{ip=server, msg=m, tcp=false}
   local got, err = cmsg:resolve(timeout)
   if got
   then
      return got:get_msg()
   end
   return nil, err
end

function resolve_msg_tcp(server, m, timeout)
   mst.a(server, 'server mandatory')
   mst.a(m and m.h and m.h.id, 'msg without mandatory id', m)
   local cmsg = msg:new{ip=server, msg=m, tcp=true}
   local got, err = cmsg:resolve(timeout)
   if got
   then
      return got:get_msg()
   end
   return nil, err
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
