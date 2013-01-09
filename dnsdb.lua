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
-- Last modified: Wed Jan  9 16:40:23 2013 mstenber
-- Edit time:     144 min
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

-- extend dnscodec's dns_rr
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

-- class used for handling single RR record (whether it's from
-- dnscodec, or synthetic created by us)

rr = mst.create_class{class='rr'}

--function rr:repr_data()
--   return '?'
--end

function rr:rdata_equals(o)
   --mst.a(o ~= rr, "can't compare with class")
   local m = dnscodec.rtype_map[self.rtype]
   if m and o[m.field]
   then
      local r = m:field_equal(rr[m.field], o[m.field])
      mst.d(' fallback field match?', r)
      return r
   end
   --self:a(o.rdata, 'no rdata', o)
   if o.rdata
   then
      local r = o.rdata == self.rdata
      mst.d(' rdata match?', r)
      return r
   end
   mst.d(' fallback field not set, no rdata -> match')
   return true
end

function rr:equals(o)
   mst.a(o.rtype and o.rclass and o.name, 'mandatory bits missing')
   return self.rtype == o.rtype 
      and self.rclass == o.rclass
      and ll_equal(self.name, o.name)
      and self:rdata_equals(o) 
      and (not self.cache_flush == not o.cache_flush)
end

function rr:contained(o)
   -- fast check - if rtype different, no, it won't
   if self.rtype ~= o.rtype then return false end

   local rclass = o.rclass or dnscodec.CLASS_IN
   local cache_flush = o.cache_flush or false

   -- consider name, rtype, rclass always
   -- and rdata, if the cache_flsuh is not set within o
   return self.rclass == rclass and 
      ll_equal(self.name, o.name) and 
      (cache_flush or self:rdata_equals(o))
end

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

function ns:iterate_rrs_for_ll(ll, f)
   -- just in case, make sure it's ll
   ll = name2ll(ll)
   local key = self:ll_key(ll)
   local l = self.nh2rr[key]
   for i, v in ipairs(l or {})
   do
      if ll_equal(v.name, ll)
      then
         f(v)
      end
   end
end

function ns:find_rr_list_for_ll(ll)
   local r = {}
   self:iterate_rrs_for_ll(ll, function (rr)
                              table.insert(r, rr)
                               end)
   return r
end

function ns:find_rr(o)
   self:a(o.name, 'missing name', o)
   self:a(o.rtype, 'missing rtype', o)
   for i, rr in ipairs(self:find_rr_list_for_ll(o.name))
   do
      if rr:contained(o)
      then
         self:d('contain match', o, rr)
         return rr
      end
   end
end

function ns:find_exact_rr(o)
   self:a(o.name, 'missing name', o)
   self:a(o.rtype, 'missing rtype', o)
   for i, rr in ipairs(self:find_rr_list_for_ll(o.name))
   do
      if rr:equals(o)
      then
         -- equals implies contains
         mst.a(rr:contained(o))
         return rr
      end
   end
end

function ns:insert_rr(o, do_copy)
   -- these fields have to be set
   self:a(o.name and o.rtype and o.rclass, 
          'one of mandatory fields is missing', o)

   -- let's see if we have _exactly_ same rr already
   local old_rr = self:find_exact_rr(o)
   if old_rr 
   then
      self:d('insert_rr reused old rr', old_rr)
      return old_rr, false
   end

   -- zap anything matching (clearly old information which is out of date)
   while self:remove_rr(o) 
   do 
      self:d('insert_rr removed one matching', o)
   end

   if self.enable_copy or do_copy == true
   then
      o = mst.table_copy(o)
      o = rr:new(o)
   elseif getmetatable(o) ~= rr
   then
      o = rr:new(o)
   end
   

   -- not found - have to add
   local ll = o.name
   local key = self:ll_key(ll)
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

function ns:foreach(f)
   return self.nh2rr:foreach_values(f)
end

