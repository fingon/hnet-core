#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skvtool.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Oct  4 13:18:34 2012 mstenber
-- Last modified: Thu Oct  4 18:12:03 2012 mstenber
-- Edit time:     39 min
--

-- minimalist tool for playing with SKV
-- features:

-- -l dump contents
-- -s set  key=value
-- -g get  key

require 'mst'
require 'skv'

_TEST = false

function create_cli()
   local cli = require "cliargs"

   cli:set_name('skvtool.lua')

   cli:optarg('KEYS', 'list of keys, or key=value pairs (=set)', '', 999)

   cli:add_flag('-d', 'enable debugging (spammy)')
   cli:add_flag('-l', 'list all key-value pairs')
   cli:add_flag("-v, --version", "prints the program's version and exits")

   return cli
end


local args = create_cli():parse()
if not args 
then
   -- something wrong happened and an error was printed
   return
end


if args.d
then
   mst.enable_debug = true
   mst.d('enabling debug')
end

if args.v
then
   return print('skvtool.lua 0.1')
end

local setted = false
if type(args.KEYS) == 'string'
then
   keys = {args.KEYS}
else
   keys = args.KEYS
end
if #keys == 1 and #keys[1] == 0
then
   keys = {}
end

if #keys == 0  and not args.l
then
   create_cli():print_help()
   return print('either key, key=value, or -l are required')
end

-- ok, we're on a mission. get skv to ~stable state
local s = skv.skv:new{long_lived=false}

local r, err = s:connect()
if not r
then
   return print('connection failure', err)
end

if args.l
then
   local st = s:get_combined_state()
   mst.d('dumping entries', mst.table_count(st))
   for k, v in pairs(st)
   do
      print(string.format("%s=%s", k, mst.repr(v)))
   end
   return
end

for i, str in ipairs(keys)
do
   local i = string.find(str, '=')
   if i
   then
      local k = string.sub(str, 1, i-1)
      local v = string.sub(str, i+1, #str)
      --local f, err = loadstring('return ' .. v)
      --mst.a(f, 'unable to loadstring', err)
      --rv, err = f()
      rv = v
      mst.a(rv, 'invalid value', v, rv, err)
      mst.d('.. setting', k, v)
      s:set(k, v)
      mst.d('.. done')
      setted = true
   else
      if setted
      then
         s:wait_in_sync()
         setted = false
      end
      k = str
      v = s:get(str)
      if #keys > 1
      then
         print(string.format("%s=%s", k, mst.repr(v)))
      else
         print(mst.repr(v))
      end
   end
end

if setted
then
   mst.d('.. waiting for sync')
   s:wait_in_sync()
   mst.d('.. done')
end
