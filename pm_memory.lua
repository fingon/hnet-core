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
-- Last modified: Thu Nov 22 17:50:13 2012 mstenber
-- Edit time:     7 min
--

-- minimalist handler, which just dumps object counts every tick;
-- _relatively_ efficient

require 'pm_handler'
require 'mst'

module(..., package.seeall)

local memory_last = {}

pm_memory = pm_handler.pm_handler:new_subclass{class='pm_memory'}

function pm_memory:tick()
   if not mst.enable_debug
   then
      return
   end
   local memory = mst.count_all_types(_G, self)
   mst.debug_count_all_types_delta(memory_last, memory)
   memory_last = memory
   -- this can be enabled for guaranteed minimization of memory use;
   -- in practise, given the pause/stepmul are set correctly
   -- somewhere, it should not be necessary and just wastes
   -- resources.. (on the other hand, so does this stuff)

   -- and then report memory usage
   mst.d('lua memory usage pre-gc (in kilobytes)', collectgarbage('count'))
   -- do full GC
   collectgarbage('collect')
   -- and then report memory usage
   mst.d('lua memory usage post-gc (in kilobytes)', collectgarbage('count'))
end

