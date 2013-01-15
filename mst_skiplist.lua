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
-- Last modified: Tue Jan 15 13:53:56 2013 mstenber
-- Edit time:     122 min
--

local mst = require 'mst'

module(...)

-- in-place (within the objects) indexed skiplist
-- memory usage: 

-- - fixed + ~40 bytes * 1 / (1 - p) within each object (and twice
-- - that if width calculation is enabled for indexing)

-- basic idea: the skiplist object itself contains only keys for
-- the different depth field names within two dedicated tables
-- (next, width), and then the first next within object o is list[next[1]]

-- parameters:
-- p = probability of being on next level (1 in p) => 2 = 50%

-- TODO: consider if storing the level of entry is worth it in the
-- skiplist item. It costs 40 bytes per item, which is nontrivial
-- amount, but with that, remove operation (at least) would be much
-- more efficient. Perhaps not worth it, as we optimize for fast
-- check-first, and fast default indexing, neither of which this would
-- affect.
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

-- overridable environment-affecting functions
function ipi_skiplist:randint(a, b)
   self.r = self.r + 1
   local r = a + self.r % (b - a + 1)
   self:a(r >= a and r <= b)
   return r
end

function ipi_skiplist.lt(o1, o2)
   return o1 < o2
end

-- utility stuff

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

-- traverse from object p while the next object is also less than o
local function traverse_p_lt(p, k, o, lt)
   local n = p[k]
   -- not lt == ge
   if not n or not lt(n, o)
   then
      return p
   end
   return traverse_p_lt(n, k, o, lt)
end

function ipi_skiplist:insert_up_to_level(o, l)
   -- we use the list object itself as 'head' object
   local p = self
   local width_enabled = self.width
   local lt = self.lt

   self:ensure_levels(l)
   mst.a(l >= 1, 'invalid random level', l)
   for i=#self.next,l+1,-1
   do
      local nk = self:get_next_key(i)
      p = traverse_p_lt(p, nk, o, lt)
      if width_enabled
      then
         -- next one is beyond us -> increment width
         local wk = self:get_width_key(i)
         p[wk] = p[wk] + 1
      end
   end
   -- have to add to these lists
   for i=l,1,-1
   do
      local nk = self:get_next_key(i)
      p = traverse_p_lt(p, nk, o, lt)
      o[nk] = p[nk]
      p[nk] = o
      -- and adjust widths, if i > 1
      if i > 1 and width_enabled
      then
         self:d('weight update level', i, o)
         local wk = self:get_width_key(i)
         -- have to determine the # of items in [p, o[ and [o, old[
         local pie = p[wk] + 1
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
   local lt = self.lt
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
   if not n or lt(o2, n)
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

function ipi_skiplist:get_first()
   local nk = self:get_next_key(1)
   return self[nk]
end

-- find item at specific index, nil if not found
function ipi_skiplist:find_at_index(idx)
   if idx <= 0
   then
      return nil, 'indexing starts at 1'
   end
   if idx > self.c
   then
      return nil, 'index out of bounds ' .. idx
   end
   local p = self
   local nk
   for i=#self.next,1,-1
   do
      nk = self:get_next_key(i)
      local wk = i > 1 and self:get_width_key(i)
      while p[nk] and idx >= (i > 1 and p[wk] or 1)
      do
         local w = (i > 1 and p[wk] or 1)
         p = p[nk]
         if idx == w
         then
            return p
         else
            idx = idx - w
         end
      end
   end
   return nil, 'not found?!?'
end

function ipi_skiplist:find_index_of(o)
   local p = self
   local nk
   local idx = 0

   for i=#self.next,1,-1
   do
      nk = self:get_next_key(i)
      local wk = i > 1 and self:get_width_key(i)
      while p[nk] and p[nk] <= o
      do
         local w = (i > 1 and p[wk] or 1)
         idx = idx + w
         p = p[nk]
      end
   end
   return idx
end

function ipi_skiplist:insert(o)
   local l = self:get_random_level()
   self.c = self.c + 1
   self:insert_up_to_level(o, l)
end

function ipi_skiplist:remove(o)
   local p = self
   local nk
   local wk
   local width_enabled = self.width
   local lt = self.lt

   for i=#self.next,1,-1
   do
      nk = self:get_next_key(i)
      p = traverse_p_lt(p, nk, o, lt)
      -- rewrite the next links as we go
      if p[nk] == o
      then
         p[nk] = o[nk]
         if i > 1 and width_enabled
         then
            wk = self:get_width_key(i)
            -- copy over width as well
            p[wk] = p[wk] + o[wk] - 1
         end
      else
         self:a(i > 1, 'not found on level 1?!?')
         if i>1 and width_enabled
         then
            wk = self:get_width_key(i)
            -- decrement width by 1
            p[wk] = p[wk] - 1
         end
      end
   end
   self.c = self.c - 1
end

function ipi_skiplist:get_next_key(i)
   self:a(i >= 1, 'no next key < 1')
   return self.next[i]
end

function ipi_skiplist:get_width_key(i)
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
   local lt = self.lt
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
         self:a(not o2 or lt(o, o2), 'ordering violation at list level', i)
         o = o2
         no = no + 1
      end
      self:a(i ~= 1 or no == self.c, 'missing items i/no', i, no)
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
         self:a(not o2 or lt(o, o2), 'ordering violation at list level', i)
         if i == 1
         then
            tw = tw + 1
         else
            tw = tw + o[wk]
         end
         o = o2
      end
      self:a(tw == self.c + 1, 'weight mismatch i/tw', i, tw)
      end
   end
end
