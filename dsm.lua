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
-- Last modified: Wed Dec 19 14:01:02 2012 mstenber
-- Edit time:     16 min
--

-- wierd testing utility class, which simulates a whole topology
-- using the fake classes

require 'skv'
require 'elsa_pa'

module(..., package.seeall)

-- simulation master entity - some shared functionality among the
-- different testcases
dsm = mst.create_class{class='dsm', mandatory={'e', 'port_offset'}}

function dsm:init()
   self.skvs = mst.array:new{}
   self.t = 0
end

function dsm:add_node(rid)
   local port = self.port_offset + #self.skvs
   local s = skv.skv:new{long_lived=true, port=port}
   self.skvs:insert(s)
   local ep = elsa_pa.elsa_pa:new{elsa=self.e, skv=s, rid=rid,
                                  time=function ()
                                     return self.t
                                  end}
   self.e:add_node(ep)
   self.nodes = nil
   return ep
end

function dsm:get_nodes()
   if not self.nodes
   then
      self.nodes = self.e.nodes:values()
   end
   return self.nodes
end

function dsm:advance_time(value)
   self.t = self.t + value
end

function dsm:uninit()
   for i, ep in ipairs(self:get_nodes())
   do
      ep:done()
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
      for i, ep in ipairs(mst.array_randlist(self:get_nodes()))
      do
         self:d(' ', ep.rid)
         if run_callback
         then
            run_callback(self, ep)
         else
            ep:run()
         end
      end
      local l = 
         self:get_nodes():filter(function (ep) return ep:should_run() end)
      if #l == 0
      then
         return true
      end
   end
end

