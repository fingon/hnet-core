#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_memory.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov 22 17:06:50 2012 mstenber
-- Last modified: Thu Nov 22 17:10:55 2012 mstenber
-- Edit time:     2 min
--

-- minimalist handler, which just dumps object counts every tick;
-- _relatively_ efficient

require 'pm_handler'
require 'mst'

module(..., package.seeall)

local memory_last = {}

pm_memory = pm_handler.pm_handler:new_subclass{class='pm_memory'}

function pm_memory:tick()
   local memory = mst.count_all_types()
   mst.debug_count_all_types_delta(memory_last, memory)
   memory_last = memory
end

