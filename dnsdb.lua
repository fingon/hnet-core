#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnsdb.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 14:09:58 2012 mstenber
-- Last modified: Mon Dec 17 14:44:23 2012 mstenber
-- Edit time:     27 min
--

-- This is a datastructure used for storing the (m)DNS
-- information. Typical example usage case is to have NS per local
-- interface, and yet another one based on data from OSPF.

-- The data is stored in a multimap based on hash of the name;
-- collisions are handled by the multimap lists.

require 'mst'
require 'dnscodec'

module(..., package.seeall)

function name2ll(name)
   mst.a(name, 'name not set?!?')
   local ntype = type(name)
   if ntype == 'table'
   then
      return name
   end
   mst.a(ntype == 'string', 'unsupported type', ntype, name)
   -- use '.' as separator, and pray hard that there isn't . within the labels
   local t = mst.string_split(name, '.')
   table.insert(t, '')
   return t
end

function ll2name(ll)
   if type(ll) == 'string'
   then
      return ll
   end
   return table.concat(ll, '.')
end

-- class used for handling single RR record (whether it's from
-- dnscodec, or synthetic created by us)
rr = mst.create_class{class='rr'}

-- namespace of RR records; it has ~fast access to RRs by name
ns = mst.create_class{class='ns'}
function ns:init()
   self.nh2rr = mst.multimap:new{}
end

function ns:repr_data()
   return mst.repr({count=self:count()})
end

function ns:ll_key(ll)
   -- just in case, make sure it's ll
   ll = name2ll(ll)
   return mst.create_hash(mst.repr(ll))
end

function ns:find_rr_list_for_ll(ll)
   -- just in case, make sure it's ll
   ll = name2ll(ll)
   local key = self:ll_key(ll)
   local l = self.nh2rr[key]
   local r = {}
   for i, v in ipairs(l or {})
   do
      if ll_equal(v.name, ll)
      then
         table.insert(r, v)
      end
   end
   return r
end

function ll_equal(ll1, ll2)
   if #ll1 ~= #ll2
   then
      return false
   end
   for i=1,#ll1
   do
      if ll1[i] ~= ll2[i] then return false end
   end
   return true
end

function ns:find_rr(o)
   self:a(o.name, 'missing name', o)
   local rtype = o.rtype
   local rclass = o.rclass or dnscodec.CLASS_IN
   self:a(o.rtype, 'missing rtype', o)

   for i, v in ipairs(self:find_rr_list_for_ll(o.name))
   do
      if v.rclass == rclass and v.rtype == rtype and ll_equal(v.name, o.name)
      then
         return v
      end
   end
end

function ns:upsert_rr(o)
   local old_rr = self:find_rr(o)
   -- if found, just update the old rr
   if old_rr
   then
      mst.table_copy(o, old_rr)
      return 
   end
   -- not found - have to add
   local ll = o.name
   local key = self:ll_key(ll)
   setmetatable(o, rr)
   self.nh2rr:insert(key, o)
end

function ns:remove_rr(o)
   local old_rr = self:find_rr(o)
   if not old_rr then return end
   local ll = o.name
   local key = self:ll_key(ll)
   self.nh2rr:remove(key, old_rr)
end

function ns:count()
   return self.nh2rr:count()
end
