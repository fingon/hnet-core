#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: delsa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Oct  5 00:09:17 2012 mstenber
-- Last modified: Sat Oct 27 10:27:52 2012 mstenber
-- Edit time:     27 min
--

require 'mst'
require 'elsa_pa'
require 'dneigh'

module(..., package.seeall)

delsa = dneigh.dneigh:new_subclass{class='delsa', mandatory={'hwf'}}

function delsa:init()
   dneigh.dneigh.init(self)
   self.nodes = {}
   self.connected = {}
end

function delsa:connect_neigh(r1, i1, r2, i2)
   -- call parent
   dneigh.dneigh.connect_neigh(self, r1, i1, r2, i2)
   -- reset connected cache
   self.connected = {}
end

function delsa:repr_data()
   return string.format('#hwf=%d #iid=%d #lsas=%d #neigh=%d #routes=%d',
                        mst.count(self.hwf),
                        mst.count(self.iid),
                        mst.count(self.lsas),
                        mst.count(self.neigh),
                        mst.count(self.routes))

end

function delsa:get_connected(rid)
   local v = self.connected[rid]
   if v then return v end
   local t = mst.set:new{}
   self:iterate_all_connected_rid(rid, 
                                  function (rid2)
                                     t:insert(rid2)
                                  end)

   -- obviously all nodes that were traversible using this start rid,
   -- share the same connected set (this makes simulation of N nodes
   -- muuch faster)
   for i, rid in ipairs(t:keys())
   do
      self.connected[rid] = t
   end
   self:a(t)
   return t
end

function delsa:get_hwf(rid)
   return self.hwf[rid]
end

function delsa:iterate_lsa(rid, f, criteria)
   local c = self:get_connected(rid)
   self:a(c)
   for rid, body in pairs(self.lsas)
   do
      if c[rid] or self.assume_connected
      then
         f{rid=rid, body=body}
      end
   end
end

function delsa:iterate_if(rid, f)
   for i, v in ipairs(self.iid[rid] or {})
   do
      f(v)
   end
end

function delsa:add_router(epa, rid)
   rid = rid or epa.rid
   self.nodes[rid] = epa
end

function delsa:notify_ospf_changed(rid)
   local epa = self.nodes[rid]
   if epa
   then
      epa:ospf_changed()
   end
end

function delsa:originate_lsa(lsa)
   self:a(lsa.type == elsa_pa.AC_TYPE)
   local old = self.lsas[lsa.rid]
   if old == lsa.body
   then
      return
   end

   self.lsas[lsa.rid] = lsa.body

   -- notify self
   self:notify_ospf_changed(lsa.rid)

   -- notify self + others that the lsas changed
   self:iterate_if(lsa.rid, 
                   function (ifo)
                      self:iterate_ifo_neigh(lsa.rid, ifo, 
                                             function (d)
                                                local rid2 = d.rid
                                                self:notify_ospf_changed(rid2)
                                             end)
                   end)
end

function delsa:change_rid()
   self.rid_changed = true
end

function delsa:route_to_rid(rid)
   self:d('route lookup', rid)
   if not self.routes then return end
   local t = self.routes[rid] 
   self:d('lookup got', t)
   if t then return t end
end
