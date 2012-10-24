#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: delsa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Fri Oct  5 00:09:17 2012 mstenber
-- Last modified: Tue Oct 16 10:56:37 2012 mstenber
-- Edit time:     9 min
--

require 'mst'
require 'elsa_pa'
require 'dneigh'

module(..., package.seeall)

delsa = dneigh.dneigh:new_subclass{class='delsa', mandatory={'hwf'}}

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

function delsa:iterate_lsa(f, criteria)
   for rid, body in pairs(self.lsas)
   do
      f{rid=rid, body=body}
   end
end

function delsa:iterate_if(rid, f)
   for i, v in ipairs(self.iid[rid] or {})
   do
      f(v)
   end
end

function delsa:originate_lsa(lsa)
   self:a(lsa.type == elsa_pa.AC_TYPE)
   self.lsas[lsa.rid] = lsa.body
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
