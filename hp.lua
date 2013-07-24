#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed May 15 14:19:01 2013 mstenber
-- Last modified: Wed Jul 24 22:56:38 2013 mstenber
-- Edit time:     68 min
--

-- This is the main file for hybrid proxy (dns<>mdns). 

-- There are two modes:

-- - manual (in which we enter topology on command line)
-- - ospf (in which we learn the topology from OSPF)

-- In both modes, we need port 53 access, so this has to be run
-- as root. 

require 'ssloop'
require 'mdns_client'
require 'hp_ospf'
require 'scb'
require 'dns_proxy'
require 'per_ip_server'
require 'skv'
require 'mst_cliargs'

-- we re-use pm's memory handler just for the tick() call it provides
require 'pm_memory'
local memory_handler = pm_memory.pm_memory:new{pm={}}

local cli = mst_cliargs.new{
   options={
      {name='ospf',
       desc='maintain configuration via OSPF (applies to --server, --listen, --rid and interfaces',
       flag=1,
      },
      {name='server',
       desc="address of upstream DNS server", 
       default=dns_const.GOOGLE_IPV6},
      {name='listen',
       desc='listen on these addresses (comma separated)',
       default={'*'},
       max=10},
      {name='domain',
       desc='the domain to provide results for',
       default='home'},
      {name='rid',
       desc="the id of the router", 
       default='router'},
      {value='interface',
       desc="interface(s) to listen proxy for", 
       max=10},
   }
                              }
local args = cli:parse()
local loop = ssloop.loop()

mst.d('initializing socket')
local o, err = scb.new_udp_socket{ip='*', 
                                  port=mdns_const.PORT,
                                  callback=true,
                                  v6only=true,
                                 }

mst.a(o, 'error initializing udp socket', err)

-- create timeout object wrapper
local mdns = mdns_client.mdns_client:new{sendto=function (...)
                                            o.s:sendto(...)
                                                end,
                                         shell=mst.execute_to_string,
                                         -- for multicastjoiner
                                         mcast6=mdns_const.MULTICAST_ADDRESS_IPV6,
                                         mcasts=o.s,                               
                                        }

function o.callback(...)
   mst.d('calling mdns recvfrom', ...)

   -- just pass the callback data directly
   mdns:recvfrom(...)
end

local runner = mdns_core.mdns_runner:new{mdns=mdns}
loop:add_timeout(runner)



-- then initialize hybrid proxy object
local function cb(...)
   return mdns:resolve_ifname_q(...)
end

local rid = args.rid

local cl = hp_ospf.hybrid_ospf

if not args.ospf
then
   cl = hp_core.hybrid_proxy
end

local hp = cl:new{rid=rid,
                  domain=args.domain,
                  server=args.server,
                  mdns_resolve_callback=cb}

-- and dns_proxy which wraps hybrid proxy

local function cb(...)
   return hp:process(...)
end

local pis = per_ip_server.per_ip_server:new{
   create_callback=function (ip)
      local o = dns_proxy.dns_proxy:new{ip=ip, 
                                        process_callback=cb}
      if not o.udp then return end
      return o
   end}

if mst.enable_debug
then
   -- start memory debugging if and only if we're running in debug
   -- mode
   ssloop.repeat_every_timedelta(10,
                                 function ()
                                    memory_handler:tick()
                                 end)
end

if args.ospf
then
   local function _update_mdns_records_from_lap()
      local label = hp:rid2label(hp.rid)
      mdns:update_own_records_from_ospf_lap(label, hp.lap)
   end
   local s = skv.skv:new{long_lived=false}
   mdns:attach_skv(s, hp_ospf.valid_lap_filter)
   hp:attach_skv(s)
   pis:attach_skv(s, hp_ospf.valid_lap_filter)

   mdns:connect(hp.rid_changed, _update_mdns_records_from_lap)
   mdns:connect(hp.lap_changed, _update_mdns_records_from_lap)

   mst.d('-- OSPF MODE!--')
else
   local function _update_mdns_records()
      local label = hp:rid2label(hp.rid)
      mdns:update_own_records(label)
   end

   -- produce interface list and set for later use, and eliminate ''
   -- interface if any (thanks, cliargs, optargs handling is not so
   -- clever :p)
   local iflist = args.interface 
   if not iflist
   then
      print('You have to specify at least one interface for non-OSPF mode.')
      cli:print_help_and_exit()
   end
   local ifset = mst.array_to_table(iflist)
   ifset[''] = nil
   setmetatable(ifset, mst.set)
   iflist = ifset:keys()
   mst.d(' iflist', iflist)

   mst.a(ifset)
   mst.d(' calling set_if_joined_set', ifset)
   mdns:set_if_joined_set(ifset)

   -- also set where DNS server listens
   pis:set_ips(args.listen or {})

   function hp:iterate_lap(f)
      for i, v in ipairs(iflist)
      do
         f{ifname=v, iid=v}
      end
   end

   -- Rather brute force approach: update the local IP information
   -- every 10 seconds if it's relevant (in practise, once every
   -- minute most likely)
   ssloop.repeat_every_timedelta(10,  _update_mdns_records)

   mst.d('-- STATIC MODE!--')
end



mst.d('entering event loop')
loop:loop()
