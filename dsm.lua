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
-- Last modified: Mon Feb 11 15:42:43 2013 mstenber
-- Edit time:     55 min
--

-- wierd testing utility class, which simulates a whole topology
-- using the fake classes

require 'skv'

module(..., package.seeall)

local DEFAULT_MAX_ITERATIONS = 1234

-- simulation master entity - some shared functionality among the
-- different testcases
dsm = mst.create_class{class='dsm', mandatory={'e', 
                                               'port_offset',
                                               'create_callback'},
                       max_iterations=DEFAULT_MAX_ITERATIONS,
                      }

function dsm:init()
   self.skvs = mst.array:new{}
   self.t = self.t or 54321
   self.start_t = self.t
end

function dsm:repr_data()
   return '?'
end

function dsm:create_node(o)
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
   self:add_node(n)
   return n
end

function dsm:add_node(o)
   self.e:add_node(o)
   self.nodes = nil
   return o
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
   self:d('set_time', self.t)

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

function dsm:run_nodes(iters, run_callback, all_first)
   iters = iters or self.max_iterations
   -- run nodes up to X iterations, or when none of them
   -- don't want to run return true if stop condition was
   -- encountered before iters iterations
   for i=1,iters
   do
      mst.d('run_nodes iteration', i)
      -- for first run, we use all nodes (if all_first given),
      -- and for subsequent runs, only filtered list no matter what
      local l = (i == 1 and all_first and self:get_nodes()) or
         self:get_nodes():filter(function (n) return n:should_run() end)
      if #l == 0
      then
         return i
      end
      for i, n in ipairs(mst.array_randlist(l))
      do
         self:d(' ', n)
         if run_callback
         then
            run_callback(self, n)
         else
            n:run()
         end
      end
   end
end

function dsm:get_elapsed_time()
   return self.t-self.start_t
end

function dsm:run_nodes_and_advance_time(iters, o)
   iters = iters or self.max_iterations
   o = o or {}
   local i = 1
   while i <= iters
   do
      mst.d('run_nodes_and_advance_time', i, self.t, 'delta', self:get_elapsed_time())
      local r = self:run_nodes(iters-i, o.run_callback)
      -- failure, not enough iterations
      if not r then return end
      i = i + r
      -- check how long we should wait until next one
      local nt = mst.min(unpack(self.nodes:map(function (n) return n:next_time() end)))
      -- success, nobody wants to run anymore
      if not nt then return true end
      if o.until_callback and o.until_callback(nt) then return true end
      self:set_time(nt)
   end
end

function dsm:run_nodes_until_delta(iters, dt)
   local t = self.t + dt
   local r = self:run_nodes_and_advance_time(iters,
                                             {until_callback=function (nt)
                                                 mst.d('until', nt, t)
                                                 return not nt or nt > t
                                             end,
                                             })
   if r
   then
      self:set_time(t)
   end
   return r
end
