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
-- Last modified: Tue Dec 18 20:46:42 2012 mstenber
-- Edit time:     72 min
--

-- This is a datastructure used for storing the (m)DNS
-- information. Typical example usage case is to have NS per local
-- interface, and yet another one based on data from OSPF.

-- The data is stored in a multimap based on hash of the name;
-- collisions are handled by the multimap lists.

-- What is _unique_? As this mdns-oriented, there's two cases:

-- cache_flush=true => name + rtype + rclass
-- cache_flush=false => name + rtypr + rclass + rdata (=~ whole rr, -ttl)

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
   -- we don't include the last empty label in the label lists we use
   --table.insert(t, '')
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
--rr = mst.create_class{class='rr'}
-- XXX - will this be really needed? just raw dicts seem enough

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
   local lowercase_ll = mst.array_map(ll, string.lower)
   local s = mst.repr(lowercase_ll)
   return mst.create_hash(s)
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
      local s1 = string.lower(ll1[i])
      local s2 = string.lower(ll2[i])
      if  s1 ~= s2 then return false end
   end
   return true
end

function rr_equals(rr, o)
   return rr.rtype == o.rtype and rr.rclass == o.rclass and ll_equal(rr.name, o.name) and rr.rdata == o.rdata
end

function rr_contains(rr, o)
   -- fast check - if rtype different, no, it won't
   if rr.rtype ~= o.rtype then return false end

   local rclass = o.rclass or dnscodec.CLASS_IN
   local cache_flush = o.cache_flush or false
   local rdata = o.rdata

   -- consider name, rtype, rclass always
   -- and rdata, if the cache_flsuh is not set within o
   return rr.rclass == rclass and 
      ll_equal(rr.name, o.name) and 
      (not rdata or cache_flush or rr.rdata == rdata)
end

function ns:find_rr(o)
   self:a(o.name, 'missing name', o)
   self:a(o.rtype, 'missing rtype', o)
   for i, rr in ipairs(self:find_rr_list_for_ll(o.name))
   do
      if rr_contains(rr, o)
      then
         return rr
      end
   end
end

function ns:insert_rr(o)
   -- zap anything matching (clearly old information which is out of date)
   while self:remove_rr(o) do end

   o = mst.table_copy(o)
   
   -- not found - have to add
   local ll = o.name
   local key = self:ll_key(ll)
   --setmetatable(o, rr)
   self.nh2rr:insert(key, o)

   return o, true
end

function ns:remove_rr(o)
   local old_rr = self:find_rr(o)
   if not old_rr then return end
   local ll = o.name
   local key = self:ll_key(ll)
   self.nh2rr:remove(key, old_rr)
   return true
end

function ns:count()
   return self.nh2rr:count()
end

function ns:values()
   return self.nh2rr:values()
end
