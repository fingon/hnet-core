#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_core_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Dec 18 21:10:33 2012 mstenber
-- Last modified: Wed Dec 19 04:25:46 2012 mstenber
-- Edit time:     36 min
--

require "busted"
require "mdns_core"
require "skv"
require "elsa_pa"
require "dnscodec"

module("mdns_core_spec", package.seeall)

dworld = mst.create_class{class='dworld'}

function dworld:init()
   self.time = 42
   self.sent = {}
end

function dworld:get_time_callback()
   return function ()
      return self.time
          end
end

function dworld:get_sendmsg_callback()
   return function (dst, data)
      table.insert(self.sent, {dst, data})
   end
end

function dworld:set_time(x)
   mst.d('time is now', x)

   mst.a(x >= self.time)
   self.time = x
end

function dworld:advance_time(x)
   self:set_time(self.time + x)
end

-- fake mdns announcement
local msg1 = dnscodec.dns_message:encode{
   an={{name={'foo'}, rdata='bar', rtype=42, cache_flush=true},
   },
                                        }

describe("mdns", function ()
            it("works", function ()
                  local s = skv.skv:new{long_lived=true, port=42535}
                  local mdns = mdns_core.mdns:new{sendmsg=true,
                                                  skv=s}
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth2', owner=true},
                           {ifname='eth1'},
                                              })
                  mdns:run()
                  mdns:recvmsg('dead:beef::1%eth0', msg1)

                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()
                  mdns:done()
                  s:done()
                   end)
            it("state machine works too", function ()
                  local dw = dworld:new{}
                  local s = skv.skv:new{long_lived=true, port=42536}
                  local mdns = mdns_core.mdns:new{sendmsg=dw:get_sendmsg_callback(), 
                                                  time=dw:get_time_callback(),
                                                  skv=s}
                  s:set(elsa_pa.OSPF_LAP_KEY, {
                           {ifname='eth0', owner=true},
                           {ifname='eth1', owner=true},
                                              })
                  expected_states = {[mdns_core.STATE_P1]=true,
                                     [mdns_core.STATE_P2]=true,
                                     [mdns_core.STATE_P3]=true,
                                     [mdns_core.STATE_PW]=true,
                                     [mdns_core.STATE_A1]=true,
                                     [mdns_core.STATE_A2]=true,
                  }
                  
                  mdns:run()
                  mdns:recvmsg('dead:beef::1%eth0', msg1)
                  local rr = mdns:get_if_own('eth1'):values()[1]
                  while mst.table_count(expected_states) > 0
                  do
                     expected_states[rr.state] = nil
                     local nt = mdns:next_time()
                     mst.a(nt)
                     dw:set_time(nt)
                     mdns:run()
                  end
                  mst.a(#dw.sent == 5, 'wrong # sent?', dw.sent)

                  s:set(elsa_pa.OSPF_LAP_KEY, {})
                  mdns:run()
                  mdns:done()
                  s:done()
                   end)
end)
