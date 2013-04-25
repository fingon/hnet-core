#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: scr.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Apr 25 10:13:25 2013 mstenber
-- Last modified: Thu Apr 25 12:31:46 2013 mstenber
-- Edit time:     52 min
--

-- coroutine event reactor - coroutine based handling of file
-- descriptors (or something else). All we care about is that the
-- 'blocking' returns a set of functions, which return true (at some
-- point).

-- Using (say) select or something on the side to handle when to call
-- scr:poll() is advisable, of course.

-- Basic idea:

-- - coroutines are started to 'do stuff'

-- - coroutines can yield at any time, with yield value consisting of
-- callbacks

-- - coroutine is resumed with the return value of callback(s), when
-- one of them returns non-nil

require 'mst'

module(..., package.seeall)

scr = mst.create_class{class='scr'}

function scr:init()
   -- pending is just list of coroutine objects we need to call
   self.pending = {}

   -- blocked consists of co, <block criteria>
   self.blocked = {}
end

function scr:repr_data()
   return mst.repr{pending=#self.pending,
                   blocked=#self.blocked}
end

function scr:run(f, ...)
   local co = coroutine.create(f)
   table.insert(self.pending, {co, ...})
end

function scr:resume_pending()
   local i = #self.pending
   if i == 0
   then
      return
   end
   local a = table.remove(self.pending, i)
   self:d('resuming', a)
   local co = a[1]
   local nargs = {coroutine.resume(co, unpack(a, 2))}
   mst.a(nargs[1] or not nargs[2],
         'error encountered', nargs[2])
   if nargs[1] and #nargs>1
   then
      nargs[1] = co
      self:d('adding to blocked', nargs)
      table.insert(self.blocked, nargs)
   else
      -- drop it - no point in 'just kidding, not really interested in wait'
      mst.d('dropping', co, nargs)

      -- final exit also looks like this.. so we treat is as exit
      --self:a(not nargs[1], 'yield without parameters not supported by reactor')
   end
   -- tail recursion - we keep this up while pending is non-empty
   self:resume_pending()
end

function scr:check_blocked()
   local i = 1
   while i <= #self.blocked
   do
      local a = self.blocked[i]
      local co = a[1]
      local ra
      for i, v in ipairs(a)
      do
         if i > 1
         then
            local r = v()
            if r
            then
               ra = ra or {}
               ra[i] = r
            end
         end
      end
      if ra
      then
         ra[1] = co
         -- make ra real array of length #b
         for i=2,#a
         do
            if ra[i] == nil
            then
               ra[i] = false
            end
         end
         self:a(#ra == #a)
         table.remove(self.blocked, i)
         table.insert(self.pending, ra)
      else
         i = i + 1
      end
   end
end


function scr:poll()
   -- we iteratively repeat following:
   -- - 'busy' coroutines
   -- - 'blocked' coroutines
   -- - until nothing happens
   self:resume_pending()
   self:check_blocked()
   self:resume_pending()
end
