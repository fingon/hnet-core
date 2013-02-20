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
-- Last modified: Wed Feb 20 20:22:34 2013 mstenber
-- Edit time:     17 min
--

require "busted"
require "dhcpv6codec"

local dhcpv6_message = dhcpv6codec.dhcpv6_message

local known_messages = {
   -- solicit
   {"014f6ef30001000e0001000118b77eb3ee6e75234e2800060004001700180008000200000019000c75234e2800000e1000001518", 
    {
       type=dhcpv6_const.MT_SOLICIT, xid=5205747,
       [1]={data="0001000118b77eb3ee6e75234e28", 
            option=dhcpv6_const.O_CLIENTID}, 
       [2]={option=dhcpv6_const.O_ORO,
            [1]=23, [2]=24, 
       }, 
       [3]={value=0, option=8}, 
       [4]={iaid=1965248040, option=25, t1=3600, t2=5400}, 
    }
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
       [2]={data="0001000118b4e92e4e65b47f205e", option=2}, 
       [3]={data="0001000118b77eb3ee6e75234e28", option=1}, 
       [4]={option=7, value=0}, 
       [5]={[1]="2000::2", option=23}, 
       [6]={data="027636036c6162076578616d706c6503636f6d00", option=24}, 
    },
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
}


describe("dhcpv6_message", function ()
            it("endecode is sane", function ()
                  for i, v in ipairs(known_messages)
                  do
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
