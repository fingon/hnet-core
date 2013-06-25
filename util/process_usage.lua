#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: process_usage.lua $
--
-- Author: Markus Stenberg <mstenber@cisco.com>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jun 24 07:26:52 2013 mstenber
-- Last modified: Tue Jun 25 11:23:09 2013 mstenber
-- Edit time:     32 min
--

-- This is ~deterministic way to kill _everything_ related to homenet
-- on a router, and to check the memory usage during every
-- intermediate step.

-- NOTE: Doing this with busybox leads to false conclusions. Busybox
-- doesn't show cached memory as free -> typically as cached grows
-- during system lifetime, the results are .. weird. Therefore, if
-- using this on OWRT box, make sure 'ps' and 'free' map to procps
-- ones, not busybox built-ins!

require 'mst'
require 'socket'

targets = {
   -- ours
   'hp.lua',
   'pm.lua',
   'bird6',

   -- started by us
   'bird4',
   'odhcp6c',
   'dnsmasq',
   'dhclient',

   -- not ours, but we configure these
   'ntpd',
   'dropbear',

   -- these can be also around, let's see how much they take..
   'uhttpd',
   'netifd',
   'ubusd',
   'telnetd',
}   

_TEST = false -- required by cliargs + strict

function create_cli()
   local cli = require "cliargs"

   cli:set_name('process_usage.lua')
   cli:add_flag('-r', 'kill in reverse order')
   return cli
end

local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end

if args.r
then
   targets = mst.array_reverse(targets)
end

function print_mem()
   -- run collectgarbage just before print_mem -> as we don't have
   -- really much state in memory, the results should be fairly exact
   -- (+ the small overhead of the lua script with mst+socket
   -- dependencies, of course)
   collectgarbage('collect')

   local s = mst.execute_to_string('free | grep buffers/cache')
   local cnt = string.match(s, '%d+')
   cnt = tonumber(cnt)
   mst.a(cnt, 'unable to find used memory - are you really using procps?', s)
   print('mem', cnt)
end

print_mem()
local pss = mst.execute_to_string('ps axw')
local psl = mst.string_split(pss, '\n')
for i, t in ipairs(targets)
do
   local found
   for i, s in ipairs(psl)
   do
      if string.find(s, t)
      then
         local pid = string.match(s, '%d+')
         found = found or 0
         found = found + 1
         mst.execute_to_string('kill -9 ' .. pid)
      end
   end
   if found
   then
      print('killed', t, found)
      socket.sleep(1)
      print_mem()
   end
end
