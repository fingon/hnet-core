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
-- Last modified: Mon Jun 10 14:02:08 2013 mstenber
-- Edit time:     53 min
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

_TEST = false -- required by cliargs + strict

function create_cli()
   local cli = require "cliargs"

   cli:set_name('hp.lua')
   cli:add_flag('--ospf', 
                'maintain configuration via OSPF (applies to --server, --listen, --rid and interfaces)')
   cli:add_opt("--server=SERVER", 
               "address of upstream DNS server", 
               dns_const.GOOGLE_IPV6)
   cli:add_opt('--listen=LISTEN',
               'listen on these addresses (comma separated)',
               '*')
   cli:add_opt("--domain=DOMAIN", "the domain 'own' to provide results for", 'home')
   cli:add_opt("--rid=RID", "the id of the router", 'router')
   cli:optarg("interface","interface(s) to listen proxy for", '', 10)
   return cli
end


local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

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
      return dns_proxy.dns_proxy:new{ip=ip, 
                                     process_callback=cb}
   end}

if args.ospf
then
   local s = skv.skv:new{long_lived=false}
   mdns:attach_skv(s, hp_ospf.valid_lap_filter)
   hp:attach_skv(s)
   pis:attach_skv(s, hp_ospf.valid_lap_filter)
   
   -- Rather brute force approach: update the local IP information
   -- every 10 seconds if it's relevant (in practise, once every
   -- minute most likely)
   ssloop.repeat_every_timedelta(10, 
                                 function ()
                                    if hp.rid
                                    then
                                       local label = hp:rid2label(hp.rid)
                                       mdns:update_own_records(label)
                                    end
                                 end)

   mst.d('-- OSPF MODE!--')
else
   -- produce interface list and set for later use, and eliminate ''
   -- interface if any (thanks, cliargs, optargs handling is not so
   -- clever :p)
   local iflist = args.interface 
   local ifset = mst.array_to_table(iflist)
   ifset[''] = nil
   setmetatable(ifset, mst.set)
   iflist = ifset:keys()

   mst.a(ifset)
   mst.d(' calling set_if_joined_set', ifset)
   mdns:set_if_joined_set(ifset)

   -- also set where DNS server listens
   pis:set_ips(mst.string_split(args.listen, ','))

   function hp:iterate_ap(f)
      for i, v in ipairs(iflist)
      do
         f{ifname=v,
           iid=v,
           rid=rid}
      end
   end
   mst.d('-- STATIC MODE!--')
end



mst.d('entering event loop')
loop:loop()
