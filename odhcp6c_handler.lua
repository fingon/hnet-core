#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: odhcp6c_handler.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Mar 26 14:16:51 2013 mstenber
-- Last modified: Tue Mar 26 14:40:32 2013 mstenber
-- Edit time:     6 min
--

-- This is the 'shell script wrapper' which should work stand-alone,
-- given correctly exported Lua path somewhere which points us in the
-- right direction

require 'mst'
require 'skv'
require 'odhcp6c_handler_core'

mst.d('creating skv')
local s = skv.skv:new{long_lived=false}
mst.d('connecting')
local r, err = s:connect()
mst.a(r, 'connection failure', err)
mst.d('creating odhcp6c_handler_core')
local o = odhcp6c_handler_core.ohc:new{skv=s, 
                                       time=os.time,
                                       getenv=os.getenv,
                                       args=arg}
mst.d('running')
o:run()
mst.d('waiting in sync')
s:wait_in_sync()
mst.d('done')

