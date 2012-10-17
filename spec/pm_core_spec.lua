#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_core_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Oct  4 23:56:40 2012 mstenber
-- Last modified: Wed Oct 17 21:32:47 2012 mstenber
-- Edit time:     38 min
--

-- testsuite for the pm_core
-- with inputs/outputs precalculated and checked to be ~sane

require 'busted'
require 'elsa_pa'
require 'pm_core'
require 'skv'
require 'codec'
require 'pa'

module("pm_core_spec", package.seeall)

local TEMP_RADVD_CONF='/tmp/radvd.conf'

local _delsa = require 'delsa'
delsa = _delsa.delsa

local arr = nil
local arri = nil

function fakeshell(s)
   arri = arri + 1
   mst.a(arri <= #arr, 'tried to consume with array empty', s)
   local t, v = unpack(arr[arri])
   mst.a(t == s, 'mismatch - expected', t, 'got', s)
   return v
end

function setup_fakeshell(a)
   arr = a
   arri = 0
end

local usp_dead_tlv = codec.usp_ac_tlv:encode{prefix='dead::/16'}

describe("pm", function ()
            local s, e, ep, pm

            before_each(function ()
                           s = skv.skv:new{long_lived=true, port=42424}
                           e = delsa:new{iid={myrid={{index=42, name='eth2'}}},
                                         lsas={rid1=usp_dead_tlv},
                                         hwf={myrid='foo'}}
                           ep = elsa_pa.elsa_pa:new{elsa=e, skv=s, rid='myrid'}

                           s:set(elsa_pa.PD_IFLIST_KEY, {'eth0', 'eth1'})
                           s:set(elsa_pa.PD_PREFIX_KEY .. '.eth0', 
                                 -- prefix[,valid]
                                 'dead::/16'
                                )
                           s:set(elsa_pa.PD_NH_KEY .. '.eth0', 
                                 -- just address
                                 'fe80:1234:2345:3456:4567:5678:6789:789a'
                                )

                           pm = pm_core.pm:new{skv=s, shell=fakeshell,
                                               radvd_conf_filename=TEMP_RADVD_CONF}
                        end)
            after_each(function ()
                          pm:done()
                          ep:done()
                          e:done()
                          s:done()
                       end)
            it("works", function ()
                  mst.d('cht', pa.create_hash_type)
                  local x = 
                     pa.create_hash_type == 'md5' and
                     {'ip -6 addr add dead:1399:9def:f860:21c:42ff:fea7:f1d9/64 dev eth2', ''} -- md5
                     or
                     {'ip -6 addr add dead:e9d2:a21b:5888:21c:42ff:fea7:f1d9/64 dev eth2', ''} -- sha1
                     
                  setup_fakeshell{
                            {"ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary",
                             [[1: lo: <LOOPBACK,UP,LOWER_UP> mtu 16436 
2: eth2: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qlen 1000
  inet6 fdb2:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic 
  inet6 dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 scope global dynamic
6: 6rd: <NOARP,UP,LOWER_UP> mtu 1480 
  inet6 ::192.168.100.100/128 scope global 
]]},
                            {'ifconfig eth2 | grep HWaddr',
                             'eth2      Link encap:Ethernet  HWaddr 00:1c:42:a7:f1:d9  '},
                            x,
                            {'ip -6 addr del dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 dev eth2', ''},
                            {'ip -6 rule',
                             [[
0:	from all lookup local 
1112:	from dead::/16 lookup 1000 
16383:	from all lookup main 
                              ]]},
                            {'ip -6 rule del from dead::/16 table 1000 1112', ''},
                         }
                  ep:run()
                  mst.a(arri == #arr, 'did not consume all?', arri, #arr)
                        end)
               end)

