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
-- Last modified: Thu May 30 15:19:40 2013 mstenber
-- Edit time:     40 min
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

function echo_process_request(req, src)
   mst.d('echoing', req)
   return req
end

function test_response_udp(msg, host, port)
   local c, err = dns_channel.get_udp_channel{port=0}
   mst.a(c, 'unable to create channel', err)
   local got
   local cmsg=dns_channel.msg:new{msg=msg, ip=host, port=port}
   local got = scr.timeouted_run_async_call(1, 
                                            function ()
                                               c:send(cmsg)
                                               return c:receive(1)
                                            end)
   mst.a(got, 'timed out - no reply')
   c:done()
   return got
end

function test_response_tcp(msg, host, port)
   local got
   -- ip/port not relevant here, they're done in get_tcp_channel
   local cmsg = dns_channel.msg:new{msg=msg}
   local got = scr.timeouted_run_async_call(1, 
                                            function ()
                                               local c, err = dns_channel.get_tcp_channel{port=0, remote_ip=host, remote_port=port}
                                               mst.a(c, 'unable to create channel', err)
                                               c:send(cmsg)
                                               local r = c:receive(1)
                                               c:done()
                                               return r
                                            end)
   mst.a(got, 'timed out - no reply')
   return got

end

describe("dns_proxy", function ()
            local p
            after_each(function ()
                          p:done()
                          p = nil
                          mst.a(scr.clear_scr())
                       end)
            it("can be initialized", function ()
                  p = dns_proxy.dns_proxy:new{ip='*',
                                              tcp_port=5354,
                                              udp_port=5355,
                                              process_callback=echo_process_request}
                   end)

            it("works #w", function ()
                  local p0 = 5356
                  p = dns_proxy.dns_proxy:new{ip='*',
                                              -- now just general port #
                                              port=p0,
                                              process_callback=echo_process_request}
                  local thost = scb.LOCALHOST
                  
                  mst.d('--udp--')

                  -- send the fake message, expect a reply within 
                  -- 1 second, or things don't work correctly
                  -- (reply should be SOMETHING)
                  local r = test_response_udp(query_dummy_aaaa, thost, p0)
                  mst.a(r, 'timed out')

                  mst.d('--tcp--')
                  
                  -- send the fake message, expect a reply within 
                  -- 1 second, or things don't work correctly
                  -- (reply should be SOMETHING)
                  local r = test_response_tcp(query_dummy_aaaa, thost, p0)
                  mst.a(r, 'timed out')
                   end)
             end)
