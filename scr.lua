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
-- Last modified: Tue Apr 30 13:04:17 2013 mstenber
-- Edit time:     129 min
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
require 'ssloop'

module(..., package.seeall)

-- main reactor class

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
   return co
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

-- socket wrapper - can do reads+writes, magic happens as appropriate,
-- using scr (+global ssloop)

-- happy assumption: scrsocket is used _only_ within coroutine that is
-- already within scr (=yield+resume works as advertised)

-- also, another happy assumption is that we can use global event loop
-- as we see fit..

scrsocket = mst.create_class{class='scrsocket',
                             mandatory={'s'}}

function scrsocket:init()

end

function scrsocket:uninit()
   self.s:close()
   self:clear_ssloop()
end

function scrsocket:clear_ssloop()
   if self.ro 
   then 
      self.ro:done() 
      self.ro = nil
   end
   if self.wo 
   then 
      self.wo:done() 
      self.wo = nil
   end
   if self.to 
   then 
      self.to:done() 
      self.to = nil
   end
end

function scrsocket:get_loop()
   return self.loop or ssloop.loop()
end

function scrsocket:get_io(reader)
   local actionable
   local loop = self:get_loop()
   local f = reader and loop.new_reader or loop.new_writer
   local o = f(loop, self.s,
               function ()
                  actionable = true
               end)
   o:start()
   local function done()
      return actionable
   end
   return done, o
end


function scrsocket:get_timeout(timeout)
   if not timeout then return end
   local elapsed
   local o = self:get_loop():new_timeout_delta(timeout,
                                               function ()
                                                  elapsed = true
                                               end)
   o:start()
   return function ()
      return elapsed
          end, o
end

function scrsocket:io_with_timeout(fun, readable, timeout)
   local r, ro = self:get_io(readable)
   self.ro = ro
   local t, to = self:get_timeout(timeout)
   self.to = to
   local rr, rt = coroutine.yield(r, t)
   self:clear_ssloop()
   if rt
   then
      return nil, 'timeout'
   end
   self:a(rr)
   return fun()
end

function scrsocket:accept(timeout)
   return self:io_with_timeout(function ()
                                  self:d('accept')
                                  return self.s:accept()
                               end, true, timeout)
end

function scrsocket:receive(pattern, timeout)
   return self:io_with_timeout(function ()
                                  self:d('receive', pattern)
                                  return self.s:receive(pattern)
                               end, true, timeout)
end

function scrsocket:receivefrom(timeout)
   return self:io_with_timeout(function ()
                                  self:d('receivefrom')
                                  return self.s:receivefrom()
                               end, true, timeout)
end

function scrsocket:send(d, timeout)
   local sent = 0
   local w, wo = self:get_io(false)
   self.wo = wo
   local t, to = self:get_timeout(timeout)
   self.to = to
   while sent < #d
   do
      -- make sure socket is writable
      local rw, rt = coroutine.yield(w, t)
      if rt
      then
         self:clear_ssloop()
         return nil, 'timeout'
      end
      sent, err = self.s:send(d, sent+1)
      if not sent then return nil, err end
   end
   self:clear_ssloop()
   wo:done()
   return true
end

function scrsocket:sendto(...)
   self:d('sendto', ...)
   self.s:sendto(...)
end

function scrsocket:close()
   -- just proxied
   self.s:close()
end

-- general utility API

function get_scr()
   -- get the scr instance (which lives in global event loop by default)
   local l = ssloop.loop()
   mst.a(l)
   if not l.scr
   then
      local s = scr:new{}
      s.get_timeout = function ()
         -- just run poll - but pretend not to have timeouts
         s:poll()
      end
      l:add_timeout(s)
      l.scr = s
   end
   return l.scr
end

function clear_scr()
   local l = ssloop.loop()
   mst.a(l)
   if l.scr
   then
      l:remove_timeout(l.scr)
      l.scr = nil
   end
end

function run(f, ...)
   return get_scr():run(f, ...)
end

function wrap_socket(s)
   mst.a(s, 'no socket provided')
   return scrsocket:new{s=s}
end
