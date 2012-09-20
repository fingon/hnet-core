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
-- Last modified: Thu Sep 20 18:12:11 2012 mstenber
-- Edit time:     58 min
--

module(..., package.seeall)

-- global debug switch
debug=false

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
      --io.stdout:setvbuf("no") 
   end
   function h:new_subclass(o)
      setmetatable(o, self)
      self.__index = self
      self.__tostring = self.tostring
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
      o = self:new_subclass(o, 1)
      assert(o.init, "missing init method?")
      if o.mandatory
      then
         -- 1 = check_parameters, 2 == h:new, 3 == whoever calls h:new
         check_parameters(tostring(o) .. ':new()', o, o.mandatory, 3)
      end
      o:init()
      return o
   end
   function h:repr()
      return nil
   end
   function h:tostring()
      local omt = getmetatable(self)
      setmetatable(self, {})
      t = tostring(self)
      setmetatable(self, omt)
      r = self:repr()
      if r
      then
         reprs = ' - ' .. r
      else
         reprs = ''
      end
      return string.format('<%s %s%s>', 
                           self.class or tostring(getmetatable(self)), 
                           t,
                           reprs)
   end
   function h:d(...)
      self:a(type(self) == 'table', "wrong self type ", type(self))
      if self.debug or debug
      then
         print(self:tostring(), ...)
      end
   end
   function h:a(stmt, ...)
      if not stmt
      then
         print(debug.traceback())
         print(self:tostring(), ...)
         error()
      end
   end
   return h
end

function a(stmt, ...)
      if not stmt
      then
         print(debug.traceback())
         print(...)
         error()
      end
end

function d(...)
   if debug
   then
      print(self:tostring(), ...)
   end
end


function pcall_and_finally(fun1, fun2)
   -- catch errors
   r, err = pcall(fun1)

   -- call finally
   fun2()

   -- and then propagate error
   if not r
   then
      error(err)
   end
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

