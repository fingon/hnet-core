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
-- Last modified: Tue Sep 25 11:40:50 2012 mstenber
-- Edit time:     115 min
--

module(..., package.seeall)

-- global debug switch
enable_debug=false

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
         o = table_copy(o)
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
   function h:repr_data(shown)
      return nil
   end
   function h:repr(shown)
      local omt = getmetatable(self)
      setmetatable(self, {})
      t = tostring(self)
      setmetatable(self, omt)
      r = self:repr_data(shown)
      if r
      then
         reprs = ' - ' .. r
      else
         reprs = table_repr(self, shown)
      end
      return string.format('<%s %s%s>', 
                           self.class or tostring(getmetatable(self)), 
                           t,
                           reprs)
   end
   function h:tostring()
      -- by default, fall back to repr()
      return self:repr()
   end

   function h:d(...)
      self:a(type(self) == 'table', "wrong self type ", type(self))
      if self.debug or enable_debug
      then
         debug_print(self:tostring(), ...)
      end
   end
   function h:a(stmt, ...)
      if not stmt
      then
         print(debug.traceback())
         debug_print(self:tostring(), ...)
         error()
      end
   end
   function h:call_callback(name, ...)
      if self[name]
      then
         self[name](...)
      end
   end
   function h:call_callback_once(name, ...)
      if self[name]
      then
         self[name](...)
         self[name] = nil
      end
   end
   return h
end

_repr_metatable = {__tostring=function (self) return repr(self) end}

function debug_print(...)
   -- rewrite all table's to have metatable which has tostring => repr wrapper, if they don't have metatable
   local tl = {}
   local al = {...}
   local sm = {}
   --print('handling arguments', #al)
   for i, v in ipairs(al)
   do
      --print(type(v), getmetatable(v))
      if type(v) == 'table' and (not getmetatable(v) or not getmetatable(v).__tostring)
      then
         --print(' setting metatable', v)
         sm[v] = getmetatable(v)
         setmetatable(v, _repr_metatable)
         table.insert(tl, v)
      end
   end
   print(...)
   for i, v in ipairs(tl)
   do
      setmetatable(v, sm[v])
      --print(' reverted metatable', v)
   end
end

function a(stmt, ...)
      if not stmt
      then
         print(debug.traceback())
         debug_print(...)
         error()
      end
end

function d(...)
   if enable_debug
   then
      debug_print(self:tostring(), ...)
   end
end


function pcall_and_finally(fun1, fun2)
   -- error propagation doesn't really matter as much.. as good tracebacks do
   if enable_debug
   then
      fun1()
      fun2()
      return
   end

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

function table_is(t)
   return type(t) == 'table'
end

-- deep copy table
function table_deep_copy_rec(t, n, already)
   -- already contains the 'already done' mapping of tables
   -- table => new table
   assert(already)

   -- first off, check if 't' already done => return it as-is
   local na = already[t]
   if na
   then
      assert(not n)
      return na
   end
   n = n or {}
   setmetatable(n, getmetatable(t))
   already[t] = n
   for k, v in pairs(t)
   do
      nk = table_is(k) and table_deep_copy_rec(k, nil, already) or k
      nv = table_is(v) and table_deep_copy_rec(v, nil, already) or v
      n[nk] = nv
   end
   return n
end

function table_deep_copy(t)
   already = {}
   return table_deep_copy_rec(t, nil, already)
end

-- shallow copy table
function table_copy(t, n)
   assert(type(t) == "table")
   n = n or {}
   for k, v in pairs(t)
   do
      n[k] = v
   end
   return n
end

-- whether table is empty or not
function table_is_empty(t)
   for k, v in pairs(t)
   do
      return false
   end
   return true
end

-- keys of a table
function table_keys(t)
   local keys = {}
   for k, v in pairs(t)
   do
      table.insert(keys, k)
   end
   return keys
end

-- sorted keys of a table
function table_sorted_keys(t)
   local keys = table_keys(t)
   table.sort(keys)
   return keys
end

-- sorted table pairs
function table_sorted_pairs_iterator(h, k)
   local t, s, sr  = unpack(h)

   if not k
   then
      i = 0
   else
      i = sr[k]
   end

   i = i + 1
   if s[i]
   then
      return s[i], t[s[i]]
   end
end

function table_sorted_pairs(t)
   local s = table_sorted_keys(t)
   local sr = {}
   for i, v in ipairs(s)
   do
      sr[v] = i
   end
   local h = {t, s, sr}
   return table_sorted_pairs_iterator, h, nil
end

-- python-style table repr
function table_repr(t, shown)
   local s = {}
   local first = true

   a(type(t) == 'table', 'non-table to table_repr', t)
   shown = shown or {}

   table.insert(s, "{")
   if shown[t]
   then
      return '...'
   end
   shown[t] = true
   for k, v in table_sorted_pairs(t)
   do
      if not first then table.insert(s, ", ") end
      table.insert(s, k .. "=")
      table.insert(s, repr(v, shown))
      first = false
   end
   table.insert(s, "}")
   return table.concat(s)
end


local _asis_repr = {['number']=true,
                    ['function']=true,
                    ['boolean']=true,
                    ['userdata']=true,
}

-- python-style repr (works on any object, calls repr() if available,
-- if not, tough
function repr(o, shown)
   local t = type(o)
   if t == 'table'
   then
      shown = shown or {}
      specific_repr = o.repr
      if specific_repr
      then
         return specific_repr(o, shown)
      end
      return table_repr(o, shown)
   elseif t == 'string'
   then
      return string.format('%q', o)
   elseif t == 'nil'
   then
      return 'nil'
   elseif _asis_repr[t]
   then
      return tostring(o)
   else
      error("unknown type " .. t)
   end
end

-- do the two objects have same repr?
function repr_equal(o1, o2)
   -- first, stronger equality constraint - if objects
   -- are same, they also have same representation (duh)
   if o1 == o2
   then
      return true
   end

   -- not same objects, fall back to doing actual repr()s (not very
   -- efficient, but correct way to compare some things' equality)
   local s1 = repr(o1)
   local s2 = repr(o2)
   return s1 == s2
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

