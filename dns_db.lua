#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_db.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 14:09:58 2012 mstenber
-- Last modified: Mon Nov  4 14:47:40 2013 mstenber
-- Edit time:     222 min
--

-- This is a datastructure used for storing the (m)DNS
-- information. Typical example usage case is to have NS per local
-- interface, and yet another one based on data from OSPF.

-- The data is stored in a multimap based on hash of the name;
-- collisions are handled by the multimap lists.

-- What is _unique_?
-- name + rtype + rclass + rdata (=~ whole rr, -ttl)
-- (cache_flush is used to clear contents of cache based on name+rtype+rclass,
-- but it should not affect storage in dns_db itself, just how it's called)

require 'mst'
require 'dns_const'
require 'dns_rdata'
local _eventful = require 'mst_eventful'.eventful
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

   -- eliminate the last empty one, if any (dns name can validly end
   -- with '.', it just means it's globally scoped (but we ignore that
   -- distinction for most part))
   if #t>0 and #t[#t] == 0
   then
      t[#t] = nil
   end
   return t
end

function ll2name(ll)
   if type(ll) == 'string'
   then
      return ll
   end
   return table.concat(ll, '.')
end

function ll2key(ll)
   -- just in case, make sure it's ll
   ll = name2ll(ll)
   local lowercase_ll = mst.array_map(ll, string.lower)

   -- space-efficient, but perhaps painful to calculate?
   --local s = mst.repr(lowercase_ll)
   --return mst.create_hash(s)

   -- computationally efficient (all we do is just concatenate lengths + data)
   local t = dns_name.encode_name(lowercase_ll)

   return table.concat(t)
end

function ll2nameish(ll)
   local ltype = type(ll)
   if ltype ~= 'table'
   then
      return ll
   end
   -- ok, it's table, let's see if we can actually convert it
   for i, v in ipairs(ll)
   do
      if string.find(v, '[.]')
      then
         return ll
      end
   end

   -- we can! so convert it to a name
   return ll2name(ll)
end


function prefix2ll(s)
   -- We do this in inverse order, and then reverse just in the end
   local p = ipv6s.new_prefix_from_ascii(s)
   local b = p:get_binary()
   local bits = p:get_binary_bits()
   local a

   if p:is_ipv4()
   then
      -- IPv4 is of format
      -- <reverse-ip>.in-addr.arpa
      a = mst.array:new(mst.table_copy(dns_const.REVERSE_LL_IPV4_INVERSE))
      for i=13,bits/8
      do
         a:insert(tostring(string.byte(string.sub(b, i, i))))
      end
   else
      -- IPv6 is of format
      -- <reverse-ip6-addr-per-hex-octet>.ip6.arpa
      a = mst.array:new(mst.table_copy(dns_const.REVERSE_LL_IPV6_INVERSE))
      -- just whole bytes?
      for i=1,bits/8
      do
         local v = string.byte(string.sub(b, i, i))
         a:insert(string.format('%x', math.floor(v / 16)))
         a:insert(string.format('%x', v % 16))
      end
   end
   a:reverse()
   return a
end

-- extend dns_codec's dns_rr
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
-- dns_codec, or synthetic created by us)

rr = mst.create_class{class='rr'}

function rr:repr_data()
   local d = {name=self.name, 
              state=self.state,
              wait_until=self.wait_until,
              valid=self.valid,
              next=self.next,
              ttl=self.ttl,
              rtype=self.rtype, 
              cache_flush=self.cache_flush}
   local m = dns_rdata.rtype_map[self.rtype]
   local f = m and m.field
   if f and self[f]
   then
      d[f] = self[f]
   else
      d.rdata = self.rdata
   end
   return mst.repr(d)
end

function rr:get_rdata()
   return dns_codec.dns_rr:produce_rdata(self)
end

function rr:rdata_equals(o)
   --mst.a(o ~= rr, "can't compare with class")
   local m = dns_rdata.rtype_map[self.rtype]
   if m and o[m.field]
   then
      local f = m.field
      local r = m:field_equal(self[f], o[f])
      --mst.d(' fallback field match?', r)
      return r
   end
   --self:a(o.rdata, 'no rdata', o)
   if o.rdata
   then
      local r = o.rdata == self.rdata
      --mst.d(' rdata match?', r)
      return r
   end
   --mst.d(' fallback field not set, no rdata -> match')
   return true
end

function rr:equals(o)
   mst.a(o.rtype and o.name, 'mandatory bits missing')
   return self.rtype == o.rtype 
      and self.rclass == (o.rclass or dns_const.CLASS_IN)
      and ll_equal(self.name, o.name)
      and rr.rdata_equals(self, o) 
      and not self.cache_flush == not o.cache_flush
end

-- namespace of RR records; it has ~fast access to RRs by name
ns = _eventful:new_subclass{class='ns',
                            events={'inserted', -- per entry
                                    'removed',
                                    'is_not_empty', -- when emptiness changes
                                    'is_empty',
                            }}
function ns:init()
   _eventful.init(self)
   self.nh2rr = mst.multimap:new{}
end

function ns:repr_data()
   return mst.repr({count=self:count()})
end

function ns:iterate_rrs(f)
   self:a(f, 'nil function')
   self.nh2rr:foreach(function (k, v)
                         f(v)
                      end)
end

function ns:iterate_rrs_safe(f)
   self:a(f, 'nil function')
   local r = {}
   self:iterate_rrs(function (rr)
                       table.insert(r, rr)
                    end)
   for i, rr in ipairs(r)
   do
      f(rr)
   end
end

function ns:iterate_rrs_for_ll(ll, f)
   -- just in case, make sure it's ll
   ll = name2ll(ll)
   local key = ll2key(ll)
   local l = self.nh2rr[key]
   for i, v in ipairs(l or {})
   do
      if ll_equal(v.name, ll)
      then
         if f(v)
         then
            break
         end
      end
   end
end

function ns:iterate_rrs_for_ll_safe(ll, f)
   local r 
   self:iterate_rrs_for_ll(ll, function (rr)
                              r = r or {}
                              table.insert(r, rr)
                               end)
   if r
   then
      for i, rr in ipairs(r)
      do
         f(rr)
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

function ns:find_rr_list(o)
   local r 
   self:a(o.name, 'missing name', o)
   self:a(o.rtype, 'missing rtype', o)
   self:iterate_rrs_for_ll(o.name, function (rr)
                              if rr:equals(o)
                              then
                                 r = r or {}
                                 table.insert(r, rr)
                              end
                                   end)
   return r
end

function ns:find_rr(o)
   self:a(o.name, 'missing name', o)
   self:a(o.rtype, 'missing rtype', o)
   local found
   self:iterate_rrs_for_ll(o.name, function (rr)
                              if rr:equals(o)
                              then
                                 found = rr
                                 return 1
                              end
                                   end)
   return found
end

-- transactionally correct multi-rr insert
-- initially, it checks based on cache_flush whether or not
-- the matching rrs should be zapped
function ns:insert_rrs(l, do_copy)
   local all = {}
   local fresh = {}

   -- first off, handle cache_flush bit
   for i, rr in ipairs(l)
   do
      if rr.cache_flush
      then
         -- get rid of anything matching it
         -- (regardless of rdata)
         local o = {name=rr.name, rtype=rr.rtype, rclass=rr.rclass}
         while self:remove_rr(o) 
         do 
            self:d('insert_rrs removed one matching', o)
         end
      end
   end

   -- then, insert all
   for i, rr in ipairs(l)
   do
      local o, is_new = self:insert_rr(rr, do_copy)
      all[rr] = o
      if is_new
      then
         fresh[rr] = o
      end
   end
   return all, fresh
end

function ns:insert_rr(o, do_copy)
   -- these fields have to be set
   self:a(o.name and o.rtype and o.rclass, 
          'one of mandatory fields is missing (name/rtype/rclass)', o)

   -- let's see if we have _exactly_ same rr already
   local old_rr = self:find_rr(o)
   if old_rr 
   then
      self:d('insert_rr reused old rr', old_rr)
      return old_rr, false
   end
   if self.enable_copy or do_copy == true
   then
      o = mst.table_copy(o)
      o = rr:new(o)
   elseif getmetatable(o) ~= rr
   then
      o = rr:new(o)
   end
   self:insert_raw(o)
   return o, true
end

function ns:insert_raw(o)
   -- not found - have to add
   local ll = o.name
   local key = ll2key(ll)
   local was_empty = self.nh2rr:is_empty()
   self.nh2rr:insert(key, o)
   self:d('calling inserted', o)
   self.inserted(o)
   if was_empty
   then
      self.is_not_empty()
   end
   return o, true
end

function ns:remove_rr(o)
   local old_rr = self:find_rr(o)
   if not old_rr then return end
   --self:d('remove_rr', old_rr)
   local ll = o.name
   local key = ll2key(ll)
   self.nh2rr:remove(key, old_rr)
   self:d('calling removed', old_rr)
   self.removed(old_rr)
   if self.nh2rr:is_empty()
   then
      self.is_empty()
   end
   return old_rr
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

