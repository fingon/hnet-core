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
-- Last modified: Mon Feb 25 15:04:33 2013 mstenber
-- Edit time:     70 min
--

-- minimalist tool for playing with SKV
-- features:

-- -l dump contents
-- -s set  key=value
-- -g get  key
-- -w wait for server to go up (forever)

require 'mst'
require 'skv'
require 'skvtool_core'
require 'socket'
local json = require "dkjson"

_TEST = false

function create_cli()
   local cli = require "cliargs"

   cli:set_name('skvtool.lua')

   cli:optarg('KEYS', 'list of keys, or key=value pairs (=set)', '', 999)

   cli:add_flag('-d', 'enable debugging (spammy)')
   cli:add_flag('-l, --list-lua', 'list all key-value pairs [Lua]')
   cli:add_flag('-L, --list-json', 'list all key-value pairs [json]')
   cli:add_flag("-v, --version", "prints the program's version and exits")
   cli:add_flag('-w', 'wait for other end to go up')
   cli:add_flag('-r', 'read key=value pairs from stdin, in -l format')
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

-- ok, we're on a mission. get skv to ~stable state
local s

while true
do
   s = skv.skv:new{long_lived=false}
   local r, err = s:connect()
   if r
   then
      break
   end
   if not args.w
   then
      return print('connection failure', err)
   end
   s:done()
   socket.sleep(1)
end

local stc = skvtool_core.stc:new{skv=s}

if args.l
then
   stc:list_all(function (x)
                   return mst.repr(x)
                end)
   return
end

if args.L
then
   stc:list_all()
   return
end

if args.r
then
   local str = io.read()
   for i, line in ipairs(mst.string_split(str, '\n'))
   do
      stc:process_key(s, line)
   end
end

stc:process_keys(keys)
