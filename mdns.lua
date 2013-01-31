#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Sun Jan 27 12:38:01 2013 mstenber
-- Last modified: Thu Jan 31 23:48:01 2013 mstenber
-- Edit time:     69 min
--

-- 'mdns' daemon, which shares state (via skv and then via OSPF AC LSA
-- TLV) with other instances of itself on other routers. The daemon
-- itself here is relatively simple, just a wrapper for mdns_core and
-- scb's UDP.

require 'mst'
require 'skv'
require 'ssloop'
require 'mdns_ospf'

local loop = ssloop.loop()

_TEST = false

function create_cli()
   local cli = require "cliargs"

   cli:set_name('mdns.lua')
   -- XXX - think about command line options we might want
   cli:add_flag("--ipv4", "support IPv4 as much as we can (which may not be much)")
   cli:add_opt("-j, --join=IFLIST","join multicast group on given (comma-separated) interfaces", nil)
   cli:add_opt("-m, --master=IFLIST","own the (comma-separated) interfaces (=forward records from joined interfaces; -m implies -j)", nil)
   return cli
end

function checked_setoption(s, o, v)
   local r, err = s:setoption(o, v)
   mst.a(r, 'error', err, o, v)
end

local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

mst.d('initializing socket')
local o, err = scb.new_udp_socket{host='*', 
                                  port=mdns_const.PORT,
                                  callback=true,
                                  v6only=(not args.ipv4),
                                 }
mst.a(o, 'error initializing udp socket', err)

-- by default, join on _all_ interfaces, what's the harm? we can
-- ignore packets from the interfaces we don't care about, anyway..
if args.ipv4
then
   local mcast4 = mdns_const.MULTICAST_ADDRESS_IPV4
   local ifaddr = '*'
   local mct4 = {multiaddr=mcast4, interface=ifaddr}
   --checked_setoption(o.s, 'ipv6-v6only', true)
   -- ignore if this fails too, v4 is just bonus, we mainly do v6
   local r, err = o.s:setoption('ip-add-membership', mct4)
   if not r
   then
      mst.d('ipv4 multicast group join failed', mct4, err)
   end
end

checked_setoption(o.s, 'ipv6-unicast-hops', 255)
checked_setoption(o.s, 'ipv6-multicast-hops', 255)
checked_setoption(o.s, 'ipv6-multicast-loop', false)

mst.d('initializing skv')

-- doesn't _have_ to be long lived, but _can_ be (pm should be the
-- long-lived process, as it passes the data between mdns and ospf
-- implementation)
local s = skv.skv:new{long_lived=true}

mst.d('initializing mdns')
local mdns = mdns_ospf.mdns:new{skv=s,
                                sendto=o.s.sendto,
                                shell=mst.execute_to_string,
                               }

function mdns:try_multicast_op(ifname, isjoin)
   local mcast6 = mdns_const.MULTICAST_ADDRESS_IPV6
   local mct6 = {multiaddr=mcast6, interface=ifname}
   local opname = (isjoin and 'ipv6-add-membership') or 'ipv6-drop-membership'
   mst.a(ifname and #ifname > 0)
   mst.d('try_multicast_op', ifname, isjoin)
   return o.s:setoption(opname, mct6)
end

-- permanently hanging around object, which implements the basic
-- timeout API (=get_timeout, run_timeout)
local runner = {}

function runner:run_timeout()
   -- just call run - timeouts are handled on per-iteration basis
   -- using the get_timeout
   mdns:run()
end

function runner:get_timeout()
   return mdns:next_time()
end

loop:add_timeout(runner)

function o.callback(...)
   mst.d('calling mdns recvfrom', ...)

   -- just pass the callback data directly
   mdns:recvfrom(...)
end

local tojoin = #args.join>0 and mst.string_split(args.join,",") or mst.array:new{}
local tomaster = #args.master>0 and mst.string_split(args.master,",") or mst.array:new{}

local joinset = tojoin:to_table()
local masterset = tomaster:to_table()

setmetatable(joinset, mst.set)
setmetatable(masterset, mst.set)

joinset = joinset:union(masterset)

mst.d(' calling set_if_joined_set', joinset)
mdns:set_if_joined_set(joinset)

mst.d(' calling set_if_master_set', masterset)
mdns:set_if_master_set(masterset)

mst.d('entering event loop')
loop:loop()


