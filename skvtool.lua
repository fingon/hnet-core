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
-- Last modified: Wed Jul 17 19:03:32 2013 mstenber
-- Edit time:     74 min
--

-- minimalist tool for playing with SKV
-- features:

-- -l dump contents
-- -s set  key=value
-- -g get  key
-- -w wait for server to go up (forever)

require 'mst'
require 'mst_cliargs'
require 'skv'
require 'skvtool_core'
require 'socket'
local json = require "dkjson"

local args = mst_cliargs.parse{
   options={
      {name='d', 
       flag=1,
       desc='enable debugging (spammy)'},
      {name='l',
       flag=1,
       alias='list-lua',
       desc='list all key-value pairs [Lua]'},
      {name='L',
       flag=1,
       alias='list-json',
       desc='list all key-value pairs [json]'},
      {name='version',
       flag=1, desc="prints the program's version and exits"},
      {name='w',
       flag=1,
       desc='wait for other end to go up'},
      {name='r', 
       flag=1, 
       desc='read key=value pairs from stdin, in -l format'},
      {value='keys', 
       desc='list of keys, or key=value pairs (=set)', 
       max=999},
   }
                              }
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
   stc:wait_in_sync()
end

stc:process_keys(args.keys or {})
