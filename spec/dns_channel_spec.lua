#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_channel_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Apr 30 18:35:23 2013 mstenber
-- Last modified: Tue Jun 18 17:55:16 2013 mstenber
-- Edit time:     25 min
--

require 'busted'
require 'dns_channel'

module('dns_channel_spec', package.seeall)

dummy_udp_channel = dns_channel.udp_channel:new_subclass{name='dummy_udp_channel', s=true}

function dummy_udp_channel:init()
   -- we don't init anything!
end

function dummy_udp_channel:socket_sendto(b, ip, port)
   self.sent = {b, ip, port}
end

describe("dns_channel", function ()
            it("resolve_udp for google works", function ()
                  local msg, err = scr.timeouted_run_async_call(1,
                                                                dns_channel.resolve_q_udp,
                                                                '8.8.8.8',
                                                                {name={'google', 'com'}, qtype=dns_const.TYPE_AAAA}, 1)
                     
                  mst.a(msg, 'resolve_q_udp failed', err)
                  mst.d('got', msg)
                  mst.a(scr.clear_scr())
                   end)
            it("resolve for google works (any) #any", function ()
                  local msg, err = scr.timeouted_run_async_call(1,
                                                                dns_channel.resolve_q,
                                                                '8.8.8.8',
                                                                {name={'google', 'com'}, qtype=dns_const.TYPE_ANY}, 1)
                  mst.a(msg, 'resolve_q failed', err)
                  mst.d('got', msg)
                  mst.a(scr.clear_scr())
                   end)
            it("should give TC bit set response iff trying to send too big #size", function ()
                  -- first case: try (non-compressible) triple query,
                  -- which is not really even supported by most DNS
                  -- servers probably. it should NOT be sent, as we
                  -- don't prune query to fit under TC limit.
                  local o = dummy_udp_channel:new{}
                  local long_name1 = {string.rep('1', 63), 
                                     string.rep('2', 63), 
                                     string.rep('3', 63),
                                     string.rep('4', 50),
                  }
                  local dq1 = {name=long_name1}
                  local long_name2 = {string.rep('5', 63), 
                                     string.rep('6', 63), 
                                     string.rep('7', 63),
                                     string.rep('8', 50),
                  }
                  local dq2 = {name=long_name2}
                  local long_name3 = {string.rep('a', 63), 
                                     string.rep('b', 63), 
                                     string.rep('c', 63),
                                     string.rep('d', 50),
                  }
                  local dq3 = {name=long_name3}
                  local msg = {qd={dq1, dq2, dq3}}
                  local cmsg = dns_channel.msg:new{msg=msg, ip=true, port=true}
                  o:send(cmsg)
                  mst.a(not o.sent, 'sent even query? b-a-d')

                  -- second case: try (non-compressible) answers. they
                  -- should be sent, with TC set.
                  local drr1 = {name=long_name1, rtype=dns_const.TYPE_A,
                                rdata_a='1.2.3.4'}
                  local drr2 = {name=long_name2, rtype=dns_const.TYPE_A,
                                rdata_a='1.2.3.4'}
                  local drr3 = {name=long_name3, rtype=dns_const.TYPE_A,
                                rdata_a='1.2.3.4'}
                  local msg = {an={drr1, drr2, drr3}}
                  local cmsg = dns_channel.msg:new{msg=msg, ip=true, port=true}
                  local r, err = o:send(cmsg)
                  mst.a(o.sent, 'not sent (even with an being too long)', r, err)
                  mst.a(msg.h.tc)

                   end)
end)
