#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dhcpv6codec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Feb 20 18:24:16 2013 mstenber
-- Last modified: Mon Apr 29 11:11:04 2013 mstenber
-- Edit time:     38 min
--

require "busted"
require "dhcpv6_codec"

local dhcpv6_message = dhcpv6_codec.dhcpv6_message

local known_messages = {
   -- solicit
   {"014f6ef30001000e0001000118b77eb3ee6e75234e2800060004001700180008000200000019000c75234e2800000e1000001518", 
    {
       type=dhcpv6_const.MT_SOLICIT, xid=5205747,
       [1]={data="0001000118b77eb3ee6e75234e28", 
            option=dhcpv6_const.O_CLIENTID}, 
       [2]={option=dhcpv6_const.O_ORO,
            [1]=dhcpv6_const.O_DNS_RNS, [2]=dhcpv6_const.O_DOMAIN_SEARCH, 
       }, 
       [3]={value=0, option=8}, 
       [4]={iaid=1965248040, option=dhcpv6_const.O_IA_PD, t1=3600, t2=5400}, 
    }
   },

   -- solicit (IA_NA)
   {'01ab1a5b0001000e0001000118c086efeeba7b99bca50008000200000003000c7b99bca500000e1000001518',
    {[1]={data="0001000118c086efeeba7b99bca5", option=1}, 
     [2]={option=8, value=0}, 
     [3]={iaid=2073672869, option=3, t1=3600, t2=5400}, 
     type=1, xid=11213403}
   },

   -- advertise
   {"024f6ef30019004575234e2800000e1000001518001a001900000e1000001c20382000deadbee05c000000000000000000000d0018000041737369676e6564203120707265666978286573292e0002000e0001000118b4e92e4e65b47f205e0001000e0001000118b77eb3ee6e75234e280007000100001700102000000000000000000000000000000200180014027636036c6162076578616d706c6503636f6d00", 
    {
       type=dhcpv6_const.MT_ADVERTISE, xid=5205747,
       [1]={
          option=dhcpv6_const.O_IA_PD, 
          iaid=1965248040, t1=3600, t2=5400,
          [1]={option=dhcpv6_const.O_IAPREFIX, 
               preferred=3600, prefix="2000:dead:bee0:5c00::/56", 
               valid=7200}, 
          [2]={code=0, message="Assigned 1 prefix(es).", option=13}, 
       }, 
       [2]={data="0001000118b4e92e4e65b47f205e", option=dhcpv6_const.O_SERVERID}, 
       [3]={data="0001000118b77eb3ee6e75234e28", option=dhcpv6_const.O_CLIENTID}, 
       [4]={option=dhcpv6_const.O_PREFERENCE, value=0}, 
       [5]={[1]="2000::2", option=dhcpv6_const.O_DNS_RNS}, 
       [6]={[1]={"v6", "lab", "example", "com"}, option=dhcpv6_const.O_DOMAIN_SEARCH}, 
    },
   },

   -- advertise (IA_NA)
   {'02ab1a5b0001000e0001000118c086efeeba7b99bca50002000e0001000118c086da1a2e8c1654c9000300417b99bca50000070800000c4e000500182000deadbee0005300000000000000a600000e1000000e10000d001500004f68206861692066726f6d20646e736d6173710007000100001700102000deadbee00053182e8cfffe1654c9', 
    {[1]={data="0001000118c086efeeba7b99bca5", option=1}, 
     [2]={data="0001000118c086da1a2e8c1654c9", option=2}, 
     [3]={[1]={addr="2000:dead:bee0:53::a6", 
               option=5, preferred=3600, valid=3600}, 
          [2]={code=0, message="Oh hai from dnsmasq", option=13}, 
          iaid=2073672869, option=3, t1=1800, t2=3150}, 
     [4]={option=7, value=0}, 
     [5]={[1]="2000:dead:bee0:53:182e:8cff:fe16:54c9", option=23}, 
     type=2, xid=11213403}
   },
   
   -- request
   {'03c050b00001000e0001000118b77eb3ee6e75234e280002000e0001000118b4e92e4e65b47f205e00060004001700180008000200000019002975234e2800000e1000001518001a001900001c2000001d4c382000deadbee05c000000000000000000', 
    {
       type=3, xid=12603568,
       [1]={data="0001000118b77eb3ee6e75234e28", option=1}, 
       [2]={data="0001000118b4e92e4e65b47f205e", option=2}, 
       [3]={[1]=23, [2]=24, option=6}, 
       [4]={option=8, value=0}, 
       [5]={[1]={option=26, preferred=7200, prefix="2000:dead:bee0:5c00::/56", valid=7500}, iaid=1965248040, option=25, t1=3600, t2=5400}, 
    },
   },
   
   -- reply
   {'07c050b00019004575234e2800000e1000001518001a001900000e1000001c20382000deadbee05c000000000000000000000d0018000041737369676e6564203120707265666978286573292e0002000e0001000118b4e92e4e65b47f205e0001000e0001000118b77eb3ee6e75234e280007000100001700102000000000000000000000000000000200180014027636036c6162076578616d706c6503636f6d00', nil
   },
   -- rebind
   {'068e237d0001000e0001000118b77eb3ee6e75234e2800060004001700180008000200000019002975234e2800000e1000001518001a001900001c2000001d4c382000deadbee05c000000000000000000', nil,
   },
   -- reply
   {'078e237d0019000c75234e2800000e10000015180002000e0001000118b4e92e4e65b47f205e0001000e0001000118b77eb3ee6e75234e280007000100001700102000000000000000000000000000000200180014027636036c6162076578616d706c6503636f6d00', nil,
   },
   -- info request
   {'0ba34e900001000a00030001827f5ea42778000800020000', 
    {[1]={data="00030001827f5ea42778", option=1}, 
     [2]={option=8, value=0}, 
     type=11, xid=10702480},
   },
   
}


describe("dhcpv6_message", function ()
            it("endecode is sane", function ()
                  for i, v in ipairs(known_messages)
                  do
                     mst.d('iteration', i)

                     -- first try decode(h)
                     local h, r = unpack(v)
                     h = string.gsub(h, "\n", "")
                     local s = mst.hex_to_string(h)
                     local o, err = dhcpv6_message:decode(s)
                     mst.a(o, 'decode error', err)

                     -- then encode(decode(h)) == h?
                     local b = dhcpv6_message:encode(o)
                     mst.a(b == s, 'encode(decode(x)) != x!')

                     if r
                     then
                        mst.a(mst.repr_equal(r, o), 'mismatch', r, o)
                     else
                        mst.d('still no description for', o)

                     end
                  end
                                   end)
                           end)
