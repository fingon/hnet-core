#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_lookup.lua $
--
-- Author: Markus Stenberg <mstenber@cisco.com>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed May 29 17:43:23 2013 mstenber
-- Last modified: Wed May 29 18:40:57 2013 mstenber
-- Edit time:     29 min
--

-- This is minimal utility which can be used to send mdns query, and
-- see what comes back, on given interface for given label (optionally
-- also support specifying rtype and rclass).

require 'dns_const'
require 'mdns_client'
require 'ssloop'
require 'scb'

_TEST = false -- required by cliargs + strict

function create_cli()
   local cli = require "cliargs"

   cli:set_name('mdns_lookup.lua')
   cli:add_opt('--timeout=TIMEOUT', 'timeout for mdns lookup', '2')
   cli:add_opt('--type=RTYPE', 'only loop up specific rtype', tostring(dns_const.TYPE_ANY))
   cli:add_opt('--class=RCLASS', 'only look up specific rclass', tostring(dns_const.CLASS_IN))
   cli:add_opt('--interface=INTERFACE', 'look up on specific interface', 'eth2')
   cli:optarg('name', 'name(s) to look up', '', 10)
   return cli
end

local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

local o, err = scb.new_udp_socket{ip='*', 
                                  port=mdns_const.PORT,
                                  callback=true,
                                  v6only=true,
                                 }


local c = mdns_client.mdns_client:new{shell=mst.execute_to_string,
                                      sendto=function (...)
                                         o.s:sendto(...)
                                      end,                          
                                      mcast6=mdns_const.MULTICAST_ADDRESS_IPV6,
                                      mcasts=o.s,                                                     
                                     }

function o.callback(...)
   mst.d('calling mdns recvfrom', ...)

   -- just pass the callback data directly
   c:recvfrom(...)
end

local runner = mdns_core.mdns_runner:new{mdns=c}

local ifname = args.interface
mst.d('ifname', ifname)

c:set_if_joined_set{[ifname]=true}

local loop = ssloop.loop()
loop:add_timeout(runner)
scr.run(function ()
           local ifo = c:get_if(ifname)
           for i, name in ipairs(args.name)
           do
              local ll = dns_db.name2ll(name)
              local q = {name=ll,
                         qclass=tonumber(args.class),
                         qtype=tonumber(args.type)}
              print('Looking up', mst.repr(q))
              local r, err = c:resolve_ifname_q(ifname, q,
                                                tonumber(args.timeout))
              if r
              then
                 print('Got', #r)
                 for i, rr in ipairs(r)
                 do
                    rr = mst.table_copy(rr)
                    for i, v in ipairs{'name', 'next', 'received_time', 'received_ttl', 'valid', 'valid_kas', 'time'}
                    do
                       rr[v] = nil
                    end
                    ifo.cache_sl:clear_object_fields(rr)
                    print(' ', mst.repr(rr))
                 end
              else
                 print('Got error', err)
              end
           end
           loop:unloop()
        end)
loop:loop()
