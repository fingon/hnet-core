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
-- Last modified: Thu Feb 28 10:50:22 2013 mstenber
-- Edit time:     46 min
--

-- This is very, very minimal fake DHCPv6 PD server; what it does, is
-- provide a canned reply to stateful DHCPv6 request flows, and
-- ignores anything else (information requests, relayed messages)
require 'mcastjoiner'
require 'dhcpv6codec'
require 'scb'
require 'ssloop'
require 'dnsdb'

local dhcpv6_message = dhcpv6codec.dhcpv6_message
local loop = ssloop.loop()

_TEST = false -- required by cliargs + strict

function create_cli()
   local cli = require "cliargs"

   cli:set_name('fakedhcpv6d.lua')
   cli:add_opt("--dns=DNSADDRESS", "address of (IPv6) DNS server")
   cli:add_opt("--search=SEARCHPATH", "search path for IPv6 DNS")
   cli:add_opt("-j, --join=IFLIST","join multicast group on given (comma-separated) interfaces", nil)
   cli:add_opt('--port=PORT', 'use non-standard server port', tostring(dhcpv6_const.SERVER_PORT))
   cli:optarg("prefix","IPv6 prefix to provide to PD requests (static) with = used as separator for class (if any)", '', 10)
   return cli
end

local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

local port = args.port
local o, err = scb.new_udp_socket{host='*', 
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
local tojoin = #args.join>0 and mst.string_split(args.join,",") or mst.array:new{}
mst.a(tojoin:count()>0, 'have to join at least one interface multicast group')
local joinset = tojoin:to_table()


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
         local v2 = {option=v.option,
                     iaid=v.iaid,
                     t1=v.t1,
                     t2=v.t2}
         -- produce IA_PD with IAPREFIXes
         table.insert(o2, v2)
         for prefix, class in pairs(prefix2class)
         do
            local v3 = {option=dhcpv6_const.O_IAPREFIX,
                        preferred=v.t1,
                        valid=v.t2,
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
   if args.dns
   then
      table.insert(o2, {option=dhcpv6_const.O_DNS_RNS, [1]=args.dns})
   end
   if args.search
   then
      local search = args.search
      search = dnsdb.name2ll(search)
      table.insert(o2, {option=dhcpv6_const.O_DOMAIN_SEARCH, [1]=search})
   end
   
   mst.d('sending reply', o2)
   local d = dhcpv6_message:encode(o2)
   s:sendto(d, src, srcport)
end

mst.d('entering event loop')
loop:loop()


