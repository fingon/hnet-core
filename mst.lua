#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Sep 19 15:13:37 2012 mstenber
-- Last modified: Thu Sep 20 11:40:30 2012 mstenber
-- Edit time:     43 min
--

ev = require "ev"

module(..., package.seeall)

-- check parameters to e.g. function
function check_parameters(fname, o, l, depth)
   assert(o and l)
   for i, f in ipairs(l) do
      if o[f] == nil
      then
         error(f .. " is mandatory parameter to " .. fname, depth)
      end
   end
end

-- create a new class
function create_class(o)
   h = o or {}
   --h.__index = h

   function h:init()
      -- nop
   end
   function h:new_subclass(o)
      setmetatable(o, self)
      self.__index = self
      self.__tostring = self.tostring
      if o.mandatory
      then
         -- 1 = check_parameters, 2 == h:new, 3 == whoever calls h:new
         check_parameters(':new()', o, o.mandatory, 3)
      end
      --o:init()
      return o
   end
   function h:new(o)
      if o
      then
         -- shallow copy is cheap insurance, allows lazy use outside
         o = copy_table(o)
      else
         o = {}
      end
      o = self:new_subclass(o)
      assert(o.init, "missing init method?")
      o:init()
      return o
   end
   function h:repr()
      return ''
   end
   function h:tostring()
      local omt = getmetatable(self)
      setmetatable(self, {})
      t = tostring(self)
      setmetatable(self, omt)
      return string.format('<%s %s - %s>', 
                           self.class or tostring(getmetatable(self)), 
                           t,
                           self:repr())
   end
   function h:d(...)
      self:a(type(self) == 'table', "wrong self type ", type(self))
      if self.debug
      then
         print(self:tostring(), ...)
      end
   end
   function h:a(stmt, ...)
      if not stmt
      then
         print(self:tostring(), ...)
         error()
      end
   end
   return h
end

-- shallow copy table
function copy_table(t, n)
   assert(type(t) == "table")
   n = n or {}
   for k, v in pairs(t)
   do
      n[k] = v
   end
   return n
end

-- index in array
function array_find(t, o)
   for i, o2 in ipairs(t)
   do
      if o == o2
      then
         return i
      end
   end
end

--- assorted testing utilities

TEST_TIMEOUT_INVALID=0.5

function run_loop_awhile(timeout)
   local loop = ev.Loop.default
   timeout = timeout or TEST_TIMEOUT_INVALID
   local t = ev.Timer.new(function(loop,timer,revents)
                             --print 'done?'
                             loop:unloop()
                          end, timeout)
   t:start(loop)
   loop:loop()
   t:stop(loop)
end

function inject_snitch(o, n, sf)
   local f = o[n]
   o[n] = function (...)
      sf(...)
      f(...)
   end
end

function inject_refcounted_terminator(o, n, c)
   local loop = ev.Loop.default
   local terminator = function ()
      c[1] = c[1] - 1
      if c[1] == 0
      then
         loop:unloop()
      end
   end
   inject_snitch(o, n, terminator)
end

function add_eventloop_terminator(o, n)
   local c = {1}
   inject_refcounted_terminator(o, n, c)
end

