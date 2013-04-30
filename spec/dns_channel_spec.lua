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
-- Last modified: Tue Apr 30 19:27:30 2013 mstenber
-- Edit time:     11 min
--

require 'busted'
require 'dns_channel'

module('dns_channel_spec', package.seeall)

describe("dns_channel", function ()
            it("resolve_udp for google works", function ()
                  local msg, err = scr.timeouted_run_async_call(1,
                                                                dns_channel.resolve_q_udp,
                                                                '8.8.8.8',
                                                                {name={'google', 'com'}, qtype=dns_const.TYPE_AAAA}, 1)
                     
                  mst.a(msg, 'dns resolution failed', err)
                  mst.d('got', msg)
                   end)
end)
