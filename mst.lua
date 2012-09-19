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
-- Last modified: Wed Sep 19 17:16:56 2012 mstenber
-- Edit time:     19 min
--

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
      o = o or {}
      setmetatable(o, self)
      self.__index = self
      if o.mandatory
      then
         -- 1 = check_parameters, 2 == h:new, 3 == whoever calls h:new
         check_parameters(':new()', o, o.mandatory, 3)
      end
      --o:init()
      return o
   end
   function h:new(o)
      o = self:new_subclass(o)
      assert(o.init, "missing init method?")
      o:init()
      return o
   end
   return h
end

-- shallow copy table
function copy_table(t)
   assert(type(t) == "table")
   n = {}
   for k, v in pairs(t)
   do
      n[k] = v
   end
   return n
end

