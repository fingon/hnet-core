#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dneigh.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Fri Oct 12 14:54:48 2012 mstenber
-- Last modified: Tue Oct 16 10:13:23 2012 mstenber
-- Edit time:     2 min
--


require 'mst'

module(..., package.seeall)

dneigh = mst.create_class{class='dneigh'}

function dneigh:init()
   self.neigh = self.neigh or {}
end

function dneigh:iterate_ifo_neigh(rid, ifo, f)
   local all_neigh = self.neigh[rid] or {}
   local if_neigh = all_neigh[ifo.index] or {}
   for rid, iid in pairs(if_neigh)
   do
      f{iid=iid, rid=rid}
   end
end


function dneigh:connect_neigh(r1, i1, r2, i2)
   function _goe(h, k)
      if not h[k]
      then
         h[k] = {}
      end
      return h[k]
   end

   function _conn(r1, i1, r2, i2)
      _goe(_goe(self.neigh, r1), i1)[r2] = i2
   end
   _conn(r1, i1, r2, i2)
   _conn(r2, i2, r1, i1)
end

