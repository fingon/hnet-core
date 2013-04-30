#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_client.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Apr 30 16:27:48 2013 mstenber
-- Last modified: Tue Apr 30 17:31:14 2013 mstenber
-- Edit time:     13 min
--

-- This is dns client module. It abstracts away actual connections +
-- reception of reply on UDP and TCP dns.

-- Caching should be probably implemented on top of this, and this
-- module should be used just for raw DNS access from coroutine which
-- can be yielded.

-- All clients need to do is just call
-- dns_client.resolve_{rr,msg}_{tcp,udp}(dns_server_ip, query_rr[, timeout]) and Bob's
-- your uncle - result will (appear to be) synchronous returning of
-- the dns_message received from remote end, or nil, if timeout
-- occurred.

-- As example, simple 'forwarder' would just call dns_client.resolve
-- for each server ip it has, with short timeout, and return the first
-- reply.

require 'scr'
require 'scb'

module(..., package.seeall)

function resolve_msg_udp(server, msg, timeout)
   local rs1 = scb.create_udp_socket{host='*', port=0}
   local s1 = scr.wrap_socket(rs1)
   local binary = dns_codec.dns_message:encode{msg}
      
   s1:sendto(binary, host, port)
   local r, ip, port = s1:receivefrom(timeout)
   return r
end

function resolve_rr_udp(server, q, timeout)
   return resolv_msg_udp(server, {qd=q}, timeout)
end

function resolve_msg_tcp(server, msg, timeout)
   
end
