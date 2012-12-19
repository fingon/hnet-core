#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dsm.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Nov 13 16:02:05 2012 mstenber
-- Last modified: Wed Dec 19 16:57:40 2012 mstenber
-- Edit time:     31 min
--

-- wierd testing utility class, which simulates a whole topology
-- using the fake classes

require 'skv'

module(..., package.seeall)

-- simulation master entity - some shared functionality among the
-- different testcases
dsm = mst.create_class{class='dsm', mandatory={'e', 
                                               'port_offset',
                                               'create_callback'}}

function dsm:init()
   self.skvs = mst.array:new{}
   self.t = 0
end

function dsm:add_node(o)
   local port = self.port_offset + #self.skvs
   local s = skv.skv:new{long_lived=true, port=port}
   self.skvs:insert(s)
   o = o or {}
   o.sm = self
   o.skv = s
   o.time = function ()
      return self.t
   end
   
   local n = self.create_callback(o)
   self.e:add_node(n)
   self.nodes = nil
   return n
end

function dsm:get_nodes()
   if not self.nodes
   then
      self.nodes = self.e.nodes:values()
   end
   return self.nodes
end

function dsm:advance_time(value)
   self:set_time(self.t + value)
end

function dsm:set_time(value)
   mst.a(type(value) == 'number', 'weird set_time', value)
   self.t = value
end

function dsm:uninit()
   for i, n in ipairs(self:get_nodes())
   do
      n:done()
   end
   for i, s in ipairs(self.skvs)
   do
      s:done()
   end

   -- make sure cleanup really was clean
   local r = ssloop.loop():clear()
   mst.a(not r, 'event loop not clear')
end

function dsm:run_nodes(iters, run_callback)
   -- run nodes up to X iterations, or when none of them
   -- don't want to run return true if stop condition was
   -- encountered before iters iterations
   for i=1,iters
   do
      mst.d('run_nodes iteration', i)
      for i, n in ipairs(mst.array_randlist(self:get_nodes()))
      do
         self:d(' ', n)
         if run_callback
         then
            run_callback(self, n)
         else
            n:run()
         end
      end
      local l = 
         self:get_nodes():filter(function (n) return n:should_run() end)
      if #l == 0
      then
         return i
      end
   end
end

function dsm:run_nodes_and_advance_time(iters, run_callback)
   local i = 1
   while i <= iters
   do
      mst.d('run_nodes_and_advance_time', i)
      local r = self:run_nodes(iters-i, run_callback)
      -- failure, not enough iterations
      if not r then return end
      i = i + r
      -- check how long we should wait until next one
      local nt = mst.min(unpack(self.nodes:map(function (n) return n:next_time() end)))
      -- success, nobody wants to run anymore
      if not nt then return true end
      self:set_time(nt)
   end
end
