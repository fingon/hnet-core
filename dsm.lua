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
-- Last modified: Wed Dec 19 13:23:08 2012 mstenber
-- Edit time:     7 min
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
   self.eps = mst.array:new{}
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
   self.eps:insert(ep)
   self.e:add_node(ep)
   return ep
end

function dsm:advance_time(value)
   self.t = self.t + value
end

function dsm:uninit()
   for i, ep in ipairs(self.eps)
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

function dsm:run_nodes(iters, clear_busy)
   -- run nodes up to X iterations, or when none of them
   -- don't want to run return true if stop condition was
   -- encountered before iters iterations
   for i=1,iters
   do
      mst.d('run_nodes iteration', i)
      for i, ep in ipairs(mst.array_randlist(self.eps))
      do
         self:d(' ', ep.rid)
         ep:run()
         if clear_busy then ep.pa.busy = nil end
      end
      local l = 
         self.eps:filter(function (ep) return ep:should_run() end)
      if #l == 0
      then
         return true
      end
   end
end

function dsm:ensure_same()
   local ep1 = self.eps[1]
   local pa1 = ep1.pa
   for i, ep in ipairs(self.eps)
   do
      local pa = ep.pa
      mst.a(pa.usp:count() == pa1.usp:count(), 'usp', pa, pa1)
      mst.a(pa.asp:count() == pa1.asp:count(), 'asp', pa, pa1)
      
      -- lap count can be bigger, if there's redundant
      -- allocations
      --mst.a(pa.lap:count() == pa1.lap:count(), 'lap', pa, pa1)
   end
end



