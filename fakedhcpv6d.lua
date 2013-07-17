#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: fakedhcpv6d.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Feb 21 11:47:15 2013 mstenber
-- Last modified: Wed Jul 17 16:48:09 2013 mstenber
-- Edit time:     71 min
--

-- This is very, very minimal fake DHCPv6 PD server; what it does, is
-- provide a canned reply to stateful DHCPv6 request flows, and
-- ignores anything else (information requests, relayed messages)
require 'mcastjoiner'
require 'dhcpv6_codec'
require 'scb'
require 'ssloop'
require 'dns_db'
require 'mst_cliargs'

local dhcpv6_message = dhcpv6_codec.dhcpv6_message
local loop = ssloop.loop()


local args = mst_cliargs.parse{
   options={
      {name='dns', desc='IPv6 DNS server', max=10, default={}},
      {name='search', desc='IPv6 search path', max=10, default={}},
      {name='join', desc='interface to join multicast group on', min=1, max=10},
      {name='port', desc='specify port to use', 
       default=tostring(dhcpv6_const.SERVER_PORT)},
      {name='pref', desc='set preferred lifetime', default='123'},
      {name='valid', desc='set valid lifetime', default='234'},
      {value='prefix', desc='IPv6 prefix to provide to PD requests (static) with = used as separator for class (if any)', max=10, default={}},
      }
                              }

local port = tonumber(args.port)
local o, err = scb.new_udp_socket{ip='*', 
                                  port=port,
                                  callback=true,
                                  v6only=true,
                                 }
mst.a(o, 'unable to create scb udp socket', err)
mst.d(' created socket on port', port)

local s = o.s
local _mcj = mcastjoiner.mcj
local j = _mcj:new{mcast6=dhcpv6_const.ALL_RELAY_AGENTS_AND_SERVERS_ADDRESS,
                   mcasts=s,
                  }
local joinset = mst.array_to_table(args.join)


mst.d(' calling set_if_joined_set', joinset)
j:set_if_joined_set(joinset)

-- parse the arguments
local prefix2class = {}
for i, pa in ipairs(args.prefix)
do
   local pref, class = unpack(mst.string_split(pa, '=', 2))
   mst.a(type(pref) == 'string')
   prefix2class[pref] = class or false
end


function o.callback(data, src, srcport)
   mst.d('got callback', #data, src, srcport, mst.string_to_hex(data))

   -- handle address
   local l = mst.string_split(src, '%')
   if #l ~= 2
   then
      mst.d('weird source address - global?', src)
      return
   end
   local addr, ifname = unpack(l)

   -- handle payload
   local o, err = dhcpv6_message:decode(data)

   mst.a(o, 'decode error', err)
   mst.d('decoded', o)

   if o.type >= dhcpv6_const.MT_REPLY
   then
      mst.d('got weird message, ignoring it', o)
      return
   end
   -- What do we need to do? 
   local o2 = {--type
               type=(o.type == dhcpv6_const.MT_SOLICIT 
                     and dhcpv6_const.MT_ADVERTISE -- only to solicits
                     or dhcpv6_const.MT_REPLY -- otherwise
               ),
               -- transaction id
               xid=o.xid,
               -- server id
               [1] = {option=dhcpv6_const.O_SERVERID, 
                      data="0001000118b4e92e4e65b47f205e"},
   }
   for i, v in ipairs(o)
   do
      if v.option == dhcpv6_const.O_CLIENTID
      then
         -- - copy O_CLIENTID
         table.insert(o2, v)
      end
      if v.option == dhcpv6_const.O_IA_PD
      then
         local pref = args.pref or v.t1
         local valid = args.valid or v.t2
         local v2 = {option=v.option,
                     iaid=v.iaid,
                     t1=pref / 2,
                     t2=pref}
         -- produce IA_PD with IAPREFIXes
         table.insert(o2, v2)
         for prefix, class in pairs(prefix2class)
         do
            local v3 = {option=dhcpv6_const.O_IAPREFIX,
                        preferred=pref,
                        valid=valid,
                        prefix=prefix}
            table.insert(v2, v3)
            -- add class option to IAPREFIX also if necessary
            if class
            then
               table.insert(v3, {option=dhcpv6_const.O_PREFIX_CLASS, value=class})
            end
            mst.execute_to_string('ip -6 route delete ' .. prefix .. ' 2>/dev/null')
            mst.execute_to_string(string.format('ip -6 route add %s dev %s via %s', prefix, ifname, addr))
         end
      end
   end
   -- add DNS parameters if any
   for i, v in ipairs(args.dns)
   do
      table.insert(o2, {option=dhcpv6_const.O_DNS_RNS, [1]=v})
   end
   for i, v in ipairs(args.search)
   do
      local search = dns_db.name2ll(v)
      table.insert(o2, {option=dhcpv6_const.O_DOMAIN_SEARCH, [1]=search})
   end
   
   mst.d('sending reply', o2)
   local d = dhcpv6_message:encode(o2)
   s:sendto(d, src, srcport)
end

mst.d('entering event loop')
loop:loop()


