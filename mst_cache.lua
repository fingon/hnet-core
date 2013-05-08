#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_cache.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed May  8 15:54:21 2013 mstenber
-- Last modified: Wed May  8 16:52:39 2013 mstenber
-- Edit time:     36 min
--

local mst = require 'mst'
local math = require 'math'
local ipairs = ipairs
local pairs = pairs

module(...)

--- cache class (with custom optional lifetime for replies, 
--- external time source, and optional maximum number of entries)

cache = mst.create_class{class='cache', 
                         mandatory={'get_callback'},
                         optional={'positive_timeout',
                                   'negative_timeout',
                                   'default_timeout',
                                   'max_items',
                                   'time_callback'}
                        }

function cache:init()
   self:clear()
end

function cache:clear()
   self.has_timeouts = self.positive_timeout or self.negative_timeout or self.default_timeout
   self.map = mst.map:new{}
   self.items = 0
   self.op = 0
   if not self.time_callback
   then
      -- generation based timeouts are nonsense
      self:a(not self.has_timeouts)

      -- default time callback is actually call counter
      self.time_callback = function ()
         self.op = self.op + 1
         return self.op
      end
   end
end

function cache:get(k)
   self:a(k ~= nil, 'no key')
   local v = self.map[k]
   if not v
   then
      return self:create(k)
   end
   -- 'v' is array, with two entries; validity and entry itself
   local valid = v[1]
   local value = v[2]
   self:d('get', now, valid, k, value)

   if self.has_timeouts
   then
      local now = self.time_callback()
      if now > valid
      then
         return self:create(k)
      else
         return value
      end
   else
      -- always valid
      return value
   end
end

function cache:create(k)
   local v, t = self.get_callback(k)
   self:set(k, v, t)
   return v
end

function cache:purge()
   local desired = math.floor(self.max_items / 2)

   if self.has_timeouts
   then
      -- 'Cheap' variant: Check for expired entries, if they consist of
      -- 'enough' things, save sorting
      local now = self.time_callback()
      local nm = mst.map:new{}

      local cnt = mst.table_count(self.map)
      self:a(cnt == self.items, 'table count mismatch', cnt, self.items)

      for k, v in pairs(self.map)
      do
         local valid = v[1]
         if now > valid
         then
            self.map[k] = nil
            self.items = self.items - 1
         end
      end

      if self.items <= desired
      then
         return
      end
   end

   -- Cost: O(n log n) - sorting re-insertion also costs O(n) even if
   -- hash is efficient but we do this on average only every n/2 times
   -- => real cost is just O(log n) which is acceptable (and closer to
   -- O(1) if we have just sensible number of entries in cache)
   local a = mst.table_map(self.map, function (k, v)
                              return {v[1], v[2], k}
                                     end)
   a:sort(function (v1, v2)
             local t1 = v1[1]
             local t2 = v2[1]
             if not t1
             then
                return false
             end
             if not t2
             then
                return true
             end
             return t1 < t2
          end)
   self:a(#a == self.items, 'weird a', a, #a, self.items)
   self.map = mst.map:new{}
   for i=#a-desired+1,#a
   do
      local v = a[i]
      --self:a(v, 'missing index', i, #a)
      self.map[v[3]] = {v[1], v[2]}
   end
   self.items = mst.table_count(self.map)
end

function cache:set(k, v, t)
   if self.items == self.max_items
   then
      self:purge()
   end

   t = t or (v and self.positive_timeout) or self.negative_timeout or self.default_timeout
   local now = self.time_callback()
   if t
   then
      t = t + now
   else
      t = now
   end
   if self.map[k]
   then
      self.items = self.items - 1
   end
   self.map[k] = {t, v}
   self.items = self.items + 1
end

