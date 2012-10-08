#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: delsa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Fri Oct  5 00:09:17 2012 mstenber
-- Last modified: Mon Oct  8 12:54:50 2012 mstenber
-- Edit time:     1 min
--

require 'mst'
require 'elsa_pa'

module(..., package.seeall)

delsa = mst.create_class{class='delsa', mandatory={'hwf'}}

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
