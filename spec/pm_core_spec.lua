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
-- Last modified: Tue Oct  9 11:21:30 2012 mstenber
-- Edit time:     29 min
--

-- testsuite for the pm_core
-- with inputs/outputs precalculated and checked to be ~sane

require 'busted'
require 'elsa_pa'
require 'pm_core'
require 'skv'
require 'codec'

local _delsa = require 'delsa'
delsa = _delsa.delsa

local arr = nil
local arri = nil

function fakeshell(s)
   arri = arri + 1
   mst.a(arri <= #arr, 'tried to consume with array empty', s)
   local t, v = unpack(arr[arri])
   mst.a(t == s)
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
                                 {'dead::/16'}
                                )

                           pm = pm_core.pm:new{skv=s, shell=fakeshell}
                        end)
            after_each(function ()
                          pm:done()
                          ep:done()
                          e:done()
                          s:done()
                       end)
            it("works", function ()
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
                            {'ip -6 addr add dead:1399:9def:f860:21c:42ff:fea7:f1d9/64 dev eth2', ''},
                            {'ip -6 addr del dead:2c26:f4e4:0:21c:42ff:fea7:f1d9/64 dev eth2', ''},


                         }
                  ep:run()
                  mst.a(arri == #arr, 'did not consume all?', arri, #arr)
                        end)
               end)

