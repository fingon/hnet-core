#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_proxy_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Apr 30 12:51:51 2013 mstenber
-- Last modified: Tue Apr 30 13:04:42 2013 mstenber
-- Edit time:     2 min
--

require "busted"
require "dns_proxy"
require "scb"

module("dns_proxy_spec", package.seeall)

describe("dns_proxy", function ()
            it("can be initialized", function ()
                  local p = dns_proxy.dns_proxy:new{tcp_port=5354,
                                                    udp_port=5354}
                  p:done()
                   end)
            it("works", function ()
                  local p = dns_proxy.dns_proxy:new{tcp_port=5354,
                                                    udp_port=5354}
                  local thost = scb.LOCALHOST
                  local p1 = 32345
                  local rs1 = scb.create_udp_socket{host=thost, port=p1}
                  local s1 = scr.wrap_socket(rs1)
                  s1:done()

                  p:done()

                   end)
            -- XXX - test TCP

             end)
