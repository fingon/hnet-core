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
-- Last modified: Tue Apr 30 17:30:59 2013 mstenber
-- Edit time:     24 min
--

require "busted"
require "dns_proxy"
require "scb"
require "scr"
require 'dns_const'
require 'dns_codec'
require 'dns_channel'

module("dns_proxy_spec", package.seeall)

local DUMMY_TTL=1234
local rr_dummy_aaaa = {name={'dummy', 'local'},
                       rdata_aaaa='f80:dead:beef::1234', 
                       rtype=dns_const.TYPE_AAAA,
                       rclass=dns_const.CLASS_IN,
                       ttl=DUMMY_TTL,
}

local query_dummy_aaaa = {qd={{name=rr_dummy_aaaa.name, qtype=dns_const.TYPE_AAAA}}}

function test_response(msg, host, port)
   local c, err = dns_channel.get_udp_channel{port=0}
   mst.a(c, 'unable to create channel', err)
   local got
   scr.run(
      function ()
         c:send_msg(msg, {host, port})
         got = c:receive_msg(1)
      end
          )
   local r = ssloop.loop():loop_until(function ()
                                         return got
                                      end, 1)
   mst.a(r, 'timed out - no reply')
   c:done()
   return got
end

describe("dns_proxy", function ()
            it("can be initialized", function ()
                  local p = dns_proxy.dns_proxy:new{tcp_port=5354,
                                                    udp_port=5354}
                  p:done()
                  scr.clear_scr()
                   end)

            it("works #w", function ()
                  local p0 = 5354
                  local p = dns_proxy.dns_proxy:new{tcp_port=p0,
                                                    udp_port=p0}
                  local thost = scb.LOCALHOST
                  
                  -- send the fake message, expect a reply within 
                  -- 1 second, or things don't work correctly
                  -- (reply should be SOMETHING)
                  local r = test_response(query_dummy_aaaa, thost, p0)
                  
                  p:done()
                  scr.clear_scr()
                   end)
            -- XXX - test TCP

             end)
