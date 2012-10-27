#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dneigh.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Oct 12 14:54:48 2012 mstenber
-- Last modified: Sat Oct 27 10:23:17 2012 mstenber
-- Edit time:     9 min
--

-- structure is:
-- neigh[rid] = 
--  {iid1={rid2=iid2,rid3=iid3,...},..}}


require 'mst'

module(..., package.seeall)

dneigh = mst.create_class{class='dneigh'}

function dneigh:init()
   self.neigh = self.neigh or {}
end

function dneigh:iterate_iid_neigh(rid, iid, f)
   local all_neigh = self.neigh[rid] or {}
   local if_neigh = all_neigh[iid] or {}
   for rid, iid in pairs(if_neigh)
   do
      f{iid=iid, rid=rid}
   end
end

function dneigh:iterate_ifo_neigh(rid, ifo, f)
   self:iterate_iid_neigh(rid, ifo.index, f)
end

function dneigh:iterate_all_connected_rid(rid, f)
   -- recursively list all nodes that are connected to the node,
   -- including self
   local seen = mst.set:new{}
   function dump(rid)
      seen:insert(rid)
      f(rid)
   end
   function rec(rid)
      for iid2, rid2 in pairs(self.neigh[rid] or {})
      do
         if not seen[rid]
         then
            dump(rid2)
            rec(rid2)
         end
      end
   end
   -- start at the rid we have
   dump(rid)
   rec(rid)
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

