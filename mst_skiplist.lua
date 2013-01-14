#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst_skiplist.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jan 14 21:35:07 2013 mstenber
-- Last modified: Mon Jan 14 23:29:12 2013 mstenber
-- Edit time:     83 min
--

local mst = require 'mst'

module(...)

-- in-place (within the objects) indexed skiplist
-- memory usage: 

-- - fixed + ~40 bytes * 1 / (1 - p) within each object

-- basic idea: the skiplist object itself contains only keys for
-- the different depth field names within two dedicated tables
-- (next, width), and then the first next within object o is list[next[1]]

-- parameters:
-- p = probability of being on next level (1 in p) => 2 = 50%
ipi_skiplist = mst.create_class{class='ipi_skiplist', 
                                mandatory={'p'}}

function ipi_skiplist:init()
   self.next = mst.array:new{}
   if self.width == nil
   then
      self.width = mst.array:new{}
   end
   self.maxrandom = 1
   self.c = 0
   self.r = 0
   self.prefix = self.prefix or 'ipi'
end

function ipi_skiplist:repr_data()
   return mst.repr{c=self.c, n=(self.next and #self.next or nil), p=self.p}
end

function ipi_skiplist:ensure_levels(i)
   while #self.next < i
   do
      local j = #self.next + 1
      local n = self.prefix .. 'n' .. j
      self.next:insert(n)
      if self.width
      then
         local w = self.prefix .. 'w' .. j
         self.width:insert(w)
         -- by default, it covers the whole span
         self[w] = self.c
      end
      -- first level is always done; second level is the first
      -- question. However, as we play with modulo, this shouldn't be
      -- a problem
      self.maxrandom = self.p ^ #self.next
   end
end

-- traverse from object p until the point where p[k] > o or is not set
local function traverse_p(p, k, o)
   local n = p[k]
   if not n or n > o
   then
      return p
   end
   return traverse_p(n, k, o)
end

function ipi_skiplist:insert_up_to_level(o, l)
   -- we use the list object itself as 'head' object
   local p = self
   local sl = #self.next
   local width_enabled = self.width
   mst.a(l >= 1, 'invalid random level', l)
   if l > sl
   then
      sl = l
   end
   for i=sl,l+1,-1
   do
      local nk = self:get_next_key(i)
      p = traverse_p(p, nk, o)
      if width_enabled
      then
         -- next one is beyond us -> increment width
         local wk = self:get_width_key(i)
         p[wk] = (p[wk] or 1) + 1
      end
   end
   -- have to add to these lists
   for i=l,1,-1
   do
      local nk = self:get_next_key(i)
      p = traverse_p(p, nk, o)
      o[nk] = p[nk]
      p[nk] = o
      -- and adjust widths, if i > 1
      if i > 1 and width_enabled
      then
         self:d('weight update level', i, o)
         local wk = self:get_width_key(i)
         -- have to determine the # of items in [p, o[ and [o, old[
         local pie = (p[wk] or 1) + 1
         local ofs = self:calculate_distance(self, p, #self.next)
         local ton = self:calculate_distance(p, o, i-1)

         if false
         then
            local nofs = ofs + ton
            -- +1 = initial link from [self]
            self:a(nofs <= self.c + 1, 'weird ton', {i=i, ofs=ofs, ton=ton, znofs=nofs})
            if ton > pie
            then
               self:dump()
            end
         end
         self:a(ton > 0 and ton <= pie,
                'calculate_distance result weird', i, ofs, ton, pie)

         p[wk] = ton
         o[wk] = pie - ton
      end
   end
end

function ipi_skiplist:calculate_distance(o, o2, i, nk, wk)
   --self:d('calculate_distance', o, o2, i, nk, wk)
   if o == o2
   then
      --self:d(' same => 0', o, o2)
      return 0
   end
   nk = nk or self:get_next_key(i)
   -- basically, descend down from o up to point where o2 should
   -- be (and if it isn't, this should still work correctly).
   -- ultimately, it should wind up on level 1 always, if it didn't
   -- start there..
   local n = o[nk]
   -- if there is no next on this level, or it is greater than 
   -- o2, check lower level
   if not n or o2 < n
   then
      if i == 1
      then
         -- by definition, it's one away (new link) on level 1
         --self:d(' level 1 => 1')
         return 1
      end
      return self:calculate_distance(o, o2, i-1)
   end
   -- ok, o2 >= n, we can look onward from n on the same level
   local w
   if i > 1
   then
      wk = wk or self:get_width_key(i)
      w = o[wk]
   else
      w = 1
   end
   return w + self:calculate_distance(n, o2, i, nk, wk)
end

function ipi_skiplist:randint(a, b)
   self.r = self.r + 1
   local r = a + self.r % (b - a + 1)
   self:a(r >= a and r <= b)
   return r
end
function ipi_skiplist:get_random_level()
   -- figure the maximum level hit we can have
   local i = self:randint(0, self.maxrandom)
   local l = 1
   local p = self.p
   local v = self.p
   while i % v == 0 and i >= v
   do
      l = l + 1
      v = v * p
   end
   return l
end

function ipi_skiplist:insert(o)
   local l = self:get_random_level()
   self.c = self.c + 1
   self:insert_up_to_level(o, l)
end

function ipi_skiplist:get_next_key(i)
   self:ensure_levels(i)
   self:a(i >= 1, 'no next key < 1')
   return self.next[i]
end

function ipi_skiplist:get_width_key(i)
   self:ensure_levels(i)
   self:a(i > 1, 'no width key <= 1')
   self:a(self.width, 'width disabled yet accessed get_width_key?')
   return self.width[i]
end


function ipi_skiplist:dump()
   self:d('dumping')
   for i=1,#self.next
   do
      self:d('level', i)
      local o = self
      local nk = self:get_next_key(i)
      while o
      do
         if i > 1 and self.width
         then
            local wk = self:get_width_key(i)
            local w = o[wk]
            self:d(' ', o, w)
         else
            self:d(' ', o)
         end
         o = o[nk]
      end
   end
end


function ipi_skiplist:sanity_check()
   
   -- make sure that _each_ list is in order, and they
   -- have sane widths (where applicable)
   for i=1,#self.next
   do
      local nk = self:get_next_key(i)
      local o = self[nk]
      local no = 0
      while o
      do
         local o2 = o[nk]
         self:a(not o2 or o < o2, 'ordering violation at list level', i)
         o = o2
         no = no + 1
      end
      self:a(i ~= 1 or no == self.c, 'missing items', i, no, self.c)
   end
   if self.width
   then
      for i=1,#self.next
      do
      local nk = self:get_next_key(i)
      local o = self[nk]

      local wk = i > 1 and self:get_width_key(i)
      local tw = (i > 1 and self[wk]) or 1
      while o
      do
         local o2 = o[nk]
         self:a(not o2 or o < o2, 'ordering violation at list level', i)
         if i == 1
         then
            tw = tw + 1
         else
            tw = tw + o[wk] or 1
         end
         o = o2
      end
      self:a(tw == self.c + 1, 'weight mismatch', i, tw, self.c)
      end
   end
end
