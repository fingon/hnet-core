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
-- Last modified: Mon Feb 11 11:19:11 2013 mstenber
-- Edit time:     254 min
--

local mst = require 'mst'
local unpack = unpack

module(...)

-- in-place (within the objects) indexed skiplist
-- memory usage: 

-- - fixed global objects and then 
--   40 bytes + ~40 bytes * 1 / (1 - p) within each object
--   (and twice that if width calculation is enabled for indexing)

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
   self.lkey = self.prefix .. 'l'
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
   -- not lt == ge => return _first one_ where n >= o
   if not n or not lt(n, o)
   then
      return p
   end
   return traverse_p_lt(n, k, o, lt)
end

local function traverse_p_idx_lt(p, nk, wk, now, idx)
   local n = p[nk]
   local w = p[wk] + now
   if w >= idx
   then
      return p, now
   end
   return traverse_p_idx_lt(n, nk, wk, w, idx)
end

-- traverse from object p while the next object is not o
local function traverse_p_upto(p, k, o, lt)
   local n = p[k]
   if not n or n == o
   then
      return p
   end
   return traverse_p_upto(n, k, o, lt)
end

function ipi_skiplist:insert_up_to_level(o, l)
   -- we use the list object itself as 'head' object
   local p = self
   local width_enabled = self.width
   local lt = self.lt

   self:ensure_levels(l)
   self:a(l >= 1, 'invalid random level', l)
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
         --self:d('weight update level', i, o)
         local wk = self:get_width_key(i)
         -- have to determine the # of items in [p, o[ and [o, old[
         local pie = p[wk] + 1
         local ton = self:calculate_distance(p, o, i-1)

         self:a(ton > 0 and ton <= pie,
                'calculate_distance result weird', i,  ton, pie)

         p[wk] = ton
         o[wk] = pie - ton
      end
   end
end

function ipi_skiplist:calculate_distance(o, o2, i, nk, wk, lt)
   lt = lt or self.lt
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
   if not n or not lt(n, o2)
   then
      if i == 1
      then
         -- by definition, it's one away (new link) on level 1
         --self:d(' level 1 => 1')
         return 1
      end
      return self:calculate_distance(o, o2, i-1, nil, nil, lt)
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
   return w + self:calculate_distance(n, o2, i, nk, wk, lt)
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
   local lk = self.lkey
   local l = o[lk]
   local lt = self.lt

   for i=#self.next,l+1,-1
   do
      nk = self:get_next_key(i)
      local wk = self:get_width_key(i)
      while p[nk] and lt(p[nk], o)
      do
         local w = p[wk]
         idx = idx + w
         p = p[nk]
      end
   end
   -- ok, we can just do linear search onwards on the level l starting
   -- at p
   local wk
   while p ~= o
   do
      if l > 1
      then
         wk = wk or self:get_width_key(l)
         idx = idx + p[wk]
      else
         idx = idx + 1
      end
      nk = self:get_next_key(l)
      p = p[nk]
   end
   return idx
end

function ipi_skiplist:insert(o)
   local l = self:get_random_level()
   local lk = self.lkey
   self.c = self.c + 1
   self:a(not o[lk], 'already inserted?', o)
   self:insert_up_to_level(o, l)
   o[lk] = l
end

function ipi_skiplist:remove_if_present(o)
   local lk = self.lkey
   local l = o[lk]
   if not l then return end
   self:remove(o)
end

function ipi_skiplist:insert_if_not_present(o)
   local lk = self.lkey
   local l = o[lk]
   if l then return end
   self:insert(o)
end

function ipi_skiplist:remove(o)
   local p = self
   local nk
   local wk
   local width_enabled = self.width
   local lt = self.lt
   local lk = self.lkey
   local l = o[lk]

   self:a(not self.iter or self.iter == o, 
          'trying to remove wrong object mid-iteration!')


   self:a(l, 'already removed?', o)
   if width_enabled
   then
      local idx = self:find_index_of(o)
      local w = 0
      for i=#self.next,l+1,-1
      do
         nk = self:get_next_key(i)
         wk = self:get_width_key(i)
         p, w = traverse_p_idx_lt(p, nk, wk, w, idx)
         
         --self:d('remove in progress', i, w, p, idx, o)

         -- decrement width by 1
         p[wk] = p[wk] - 1
      end

      -- make sure o >= p (or self)
      self:a(p == self or not lt(o, p), 'went too far', o, p)
   else
      for i=#self.next,l+1,-1
      do
         nk = self:get_next_key(i)
         -- we can only traverse to less than node at most here as
         -- otherwise we may wind up skipping cases where o equal
         -- p.next, but ordering happens to be off..
         p = traverse_p_lt(p, nk, o, lt)
      end
      -- have to make sure p is strictly less than o; 
      -- otherwise equal-o cases may not work as advertised
      self:a(p==self or lt(p, o), 'went too far')
   end

   for i=l,1,-1
   do
      nk = self:get_next_key(i)
      p = traverse_p_upto(p, nk, o, lt)
      -- rewrite the next links as we go
      self:a(p[nk] == o, 'not found where it should be', i, o)
      p[nk] = o[nk]
      if i > 1 and width_enabled
      then
         wk = self:get_width_key(i)
         -- copy over width as well
         p[wk] = p[wk] + o[wk] - 1
      end
   end
   self.c = self.c - 1
   self:clear_object_fields(o)
end

-- remove list membership information, if any
-- (this should be used only if you really know what you're
-- doing, e.g. when doing table.copy and wanting to clean up the new object)
function ipi_skiplist:clear_object_fields(o)
   local lk = self.lkey
   local l = o[lk]
   local width_enabled = self.width

   if not l
   then
      return
   end
   -- if it's of different list of same type, it's still ok
   -- => create fields here
   --self:a(l <= #self.next, 'fields from wrong list?', o)
   self:ensure_levels(l)
   o[lk] = nil
   for i=1,l
   do
      local nk = self:get_next_key(i)
      self:a(nk, 'weird i', i, l)
      o[nk] = nil
      if i > 1 and width_enabled
      then
         local wk = self:get_width_key(i)
         o[wk] = nil
      end
   end
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

-- iterate through skiplist entries, as long as f returns non-nil (it
-- is safe to remove current items, but _not_ 'any' items)
function ipi_skiplist:iterate_while(f)
   if self.c < 1
   then
      return
   end
   self:a(not self.iter, 'nested iteration in progress - probably broken code')
   local nk = self:get_next_key(1)
   local n = self[nk]
   local i = 1
   local lk = self.lkey

   while n
   do
      -- ensure nobody has changed the list under us
      -- (removing current is ok, but removing subsequent ones
      -- isn't)
      self:a(n[lk], 'somehow entry disappeared off list', n)
      local n2 = n[nk]
      self.iter = n
      if not f(n, i)
      then
         self.iter = nil
         return
      end
      i = i + 1
      n = n2
   end
   self.iter = nil
end

-- utilities

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
         -- not lt == ge
         self:a(not o2 or not lt(o2, o), 'ordering violation at list level', i)
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
      -- super-painful approach - make sure _all_ weights are correct
      -- for _each_ item; however, transitively, we can do this by
      -- simply keeping track of the most recent entry they were
      -- correct for (and the value), and just incrementing the number
      -- of items since..
      
      local w = 0
      local lk = self.lkey
      -- store {object, weight} pairs for each level
      local pw = {}
      self:iterate_while(function (o)
                            w = w + 1
                            local l = o[lk]
                            -- for 1st level, no point, they're
                            -- implicitly correct
                            for i=2,l
                            do
                               local nk = self:get_next_key(i)
                               local wk = self:get_width_key(i)
                               local t = pw[i] or {self, 0}
                               local o2, w2 = unpack(t)
                               while o2 and o2 ~= o
                               do
                                  w2 = w2 + o2[wk]
                                  o2 = o2[nk]
                               end
                               self:a(o2, 'not found at all on level', i)
                               self:a(w2 == w, 'weight mismatch', w, w2)
                               pw[i] = {o, w}
                            end
                            return true
                         end)
   end
end
