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
-- Last modified: Wed Dec 19 13:24:27 2012 mstenber
-- Edit time:     53 min
--

-- this is variant with the neighbor topology + various pieces of
-- LSA/AC information stored within additionally. It is useful for
-- simulating number of elsa_pa nodes.

require 'mst'
require 'elsa_pa'
require 'dneigh'

module(..., package.seeall)

delsa = dneigh.dneigh:new_subclass{class='delsa', mandatory={'hwf'}}

function delsa:init()
   dneigh.dneigh.init(self)
   self.lsas = self.lsas or {}
end

function delsa:repr_data()
   return string.format('#hwf=%d #iid=%d #lsas=%d #neigh=%d #routes=%d',
                        mst.count(self.hwf),
                        mst.count(self.iid),
                        mst.count(self.lsas),
                        mst.count(self.neigh),
                        mst.count(self.routes))

end

function delsa:get_hwf(rid)
   return self.hwf[rid]
end

function delsa:iterate_lsa(rid0, f, criteria)
   local c = self:get_connected(rid0)
   self:a(c)
   self:d('iterate_lsa', rid0)

   for rid, body in pairs(self.lsas)
   do
      if c[rid] or self.assume_connected
      then
         self:d(' matched', rid)
         f{rid=rid, body=body}
      else
         self:d(' not reachable', rid)
      end
   end
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
      self:d('originate_lsa failed, same body', lsa.rid)
      return
   end

   self:d('originate_lsa - new lsa for', lsa.rid)

   self.lsas[lsa.rid] = lsa.body

   -- notify self + others that the lsas changed
   for rid, _ in pairs(self:get_connected(lsa.rid))
   do
      self:d(' notifying change', rid)
      self:notify_ospf_changed(rid)
   end
end

function delsa:change_rid()
   self.rid_changed = true
end

