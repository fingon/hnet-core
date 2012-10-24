#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mst.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Sep 19 15:13:37 2012 mstenber
-- Last modified: Fri Oct 19 13:15:53 2012 mstenber
-- Edit time:     465 min
--

-- data structure abstractions provided:

-- array_* = table with values in values, number indexes
-- set_* = table with values in keys
-- table_* = normal Python-style dictionary
--  class called 'dict' to prevent conflicts

require 'strict'

module(..., package.seeall)

-- global debug switch
enable_debug=os.getenv("ENABLE_MST_DEBUG") or false

-- enable own assert
enable_assert=true

-- forward declare types
array = nil
map = nil
set = nil

-- check parameters to e.g. function
function check_parameters(fname, o, l, depth)
   depth = depth or 2
   assert(o and l)
   for i, f in ipairs(l) do
      if o[f] == nil
      then
         error(f .. " is mandatory parameter to " .. fname, depth)
      end
   end
end

-- baseclass used as base for all classes

-- magic features:

-- - mandatory contains array with list of mandatory parameters for
--   constructor

-- - events contains array of events (=magic callback-like things) the
--   class produces (event class is instantiated for each)
--   in new.. and in done, they're cleared out correctly

baseclass = {}

function baseclass:init()
end

function baseclass:uninit()
end

function baseclass:done()
   if self._is_done
   then
      return
   end
   self._is_done = true
   self:uninit()

   -- get rid of observers
   -- they're keyed (event={fun, fun..})
   for k, l in pairs(self._observers or {})
   do
      for i, v in ipairs(l)
      do
         k:remove_observer(v)
      end
   end
   self._observers = nil

   -- get rid of events
   for i, v in ipairs(self.events or {})
   do
      local o = self[v]
      self:a(o, "event missing")
      o:done()
      self[v] = nil
   end
end

function baseclass:new_subclass(o)
   return create_class(o, self)
end

function baseclass:new(o)
   if o
   then
      -- shallow copy is cheap insurance, allows lazy use outside
      o = table_copy(o)
   else
      o = {}
   end
   local cmt = getmetatable(self).cmt

   mst.a(cmt, "missing child-metatable", self)
   setmetatable(o, cmt)

   mst.a(o.init, "missing init method?", self)
   if o.mandatory
   then
      -- 1 = check_parameters, 2 == baseclass:new, 3 == whoever calls baseclass:new
      check_parameters(tostring(o) .. ':new()', o, o.mandatory, 3)
   end
   
   -- set up event handlers (if any)
   for i, v in ipairs(o.events or {})
   do
      --print('creating event handler', v)
      o[v] = event:new()
   end

   o:init()
   return o
end

function baseclass:connect(ev, fun)
   self:a(ev, 'null event')
   self:a(fun, 'null fun')

   -- connect event 'ev' to local observer function 'fun'
   -- (and keep the connection up as long as we are)

   -- first, update local _observers
   if not self._observers
   then
      self._observers = {}
   end
   local t = self._observers[ev] or {}
   self._observers[ev] = t
   table.insert(t, fun)

   -- then call the event itself to add the observer
   ev:add_observer(fun)
end

function baseclass:repr_data(shown)
   return nil
end

function baseclass:repr(shown)
   local omt = getmetatable(self)
   setmetatable(self, {})
   local t = tostring(self)
   setmetatable(self, omt)
   local r = self:repr_data(shown)
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

function baseclass:tostring()
   -- by default, fall back to repr()
   return self:repr()
end

function baseclass:d(...)
   self:a(type(self) == 'table', "wrong self type ", type(self))
   if self.debug or enable_debug
   then
      debug_print(self:tostring(), ...)
   end
end

function baseclass:a(stmt, ...)
   if not enable_assert
   then
      assert(stmt, ...)
      return
   end
   if not stmt
   then
      print(debug.traceback())
      debug_print(self:tostring(), ...)
      error(self:tostring() .. ' assertion failed', 2)
   end
end

function baseclass:call_callback(name, ...)
   if self[name]
   then
      self[name](...)
   end
end

function baseclass:call_callback_once(name, ...)
   if self[name]
   then
      self[name](...)
      self[name] = nil
   end
end

-- create a new class with the given superclass(es)
-- (the extra arguments)
function create_class(o, ...)
   local ts = function (self)
      return self.tostring(self)
   end

   local scs = {...}
   if #scs == 0
   then
      scs = {baseclass}
   end
   mst.a(#scs == 1, "no support for > 1 superclass for now", #scs)
   h = o or {}
   -- created instances will index h, and have tostring
   local cmt = {__index = h,
                __tostring = ts}
   -- also, do inherited indexing of superclasses, and have tostring
   -- for class too
   setmetatable(h, {__index=scs[1],
                    __tostring=ts,
                    cmt=cmt})
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
   if not enable_assert
   then
      assert(stmt, ...)
      return
   end
   if not stmt
   then
      print(debug.traceback())
      debug_print(...)
      error('assertion failed', 2)
   end
end

function d(...)
   if enable_debug
   then
      debug_print(...)
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
   local r, err = pcall(fun1)

   -- call finally
   fun2()

   -- and then propagate error
   if not r
   then
      error(err)
   end
end

--- array handling

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

-- remove from array (inefficient, sigh)
function array_remove(t, o)
   local i = array_find(t, o)
   if i
   then
      table.remove(t, i)
      return true
   end
end

function array_is(t)
   -- whether it's actually table
   if not table_is(t)
   then
      return
   end
   local cnt = table_count(t)
   for i=1,cnt
   do
      if t[i] == nil
      then
         return
      end
   end
   return true
end

function array_repr(t, shown)
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
   for i, v in ipairs(t)
   do
      if i > 1
      then
         table.insert(s, ", ")
      end
      table.insert(s, repr(v, shown))
   end
   table.insert(s, "}")
   return table.concat(s)
end

-- transform array to table, with default value v if provided
function array_to_table(a, default, dest)
   local t = dest or map:new()
   for i, v in ipairs(a)
   do
      t[v] = default or true
   end
   return t
end

-- array foreach
function array_foreach(a, fun)
   for _, v in ipairs(a)
   do
      fun(v)
   end
end

-- array map 
function array_map(a, fun)
   return table_map(a, function (k, v)
                       return fun(v)
                       end)
end

-- array filtering
function array_filter(a, fun)
   local t = array:new()
   for i, v in ipairs(a)
   do
      if fun(v)
      then
         t:insert(v)
      end
   end
   return t
end

function array_slice(a, i1, i2)
   function convert_real(i)
      if i < 0
      then
         i = 1 + #a + i
      end
      return i
   end
   i1 = i1 or 1
   i2 = i2 or #a
   i1 = convert_real(i1)
   i2 = convert_real(i2)
   local t = array:new{}
   for i=i1,i2
   do
      t:insert(a[i])
   end
   return t
end

function array_extend(self, l)
   for i, v in ipairs(l)
   do
      table.insert(self, v)
   end
end

array = create_class{class='array',
                     filter=array_filter,
                     find=array_find,
                     foreach=array_foreach,
                     insert=table.insert,
                     join=table.concat,
                     map=array_map,
                     remove=array_remove,
                     remove_index=table.remove,
                     repr=array_repr,
                     slice=array_slice,
                     sort=table.sort,
                     to_table=array_to_table,
                     extend=array_extend,
                    }

function array:clear()
   while #self > 0
   do
      self[#self] = nil
   end
end

function array:count()
   return #self
end

function array:is_empty()
   return #self == 0
end

function array:to_set()
   return array_to_table(self, nil, set:new())
end

--- string utilities

function string_ipairs_iterator(s, i)
   i = i + 1
   if i > #s 
   then
      return
   end
   local ss = string.sub(s, i, i)
   return i, ss
end

function string_ipairs(s, st)
   mst.a(type(s) == "string", "non-string input", s)
   st = st or 1
   return string_ipairs_iterator, s, st-1
end

function string_to_table(s)
   local t = map:new()
   for i, c in string_ipairs(s)
   do
      t[c] = true
   end
   return t
end

function string_strip(s)
  -- from PiL2 20.4
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

function string_rstrip(s)
  -- from PiL2 20.4
  return (s:gsub("^(.-)%s*$", "%1"))
end

local _my_varok_table = false

function string_is_varok(s)
   local t = _my_varok_table
   if not t
   then
      t = string_to_table("1234567890abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_")
      _my_varok_table = t
   end
   
   mst.a(type(s) == 'string', 'string_is_varok with non-string', s)
   mst.a(t ~= nil, '_my_varok_table not set')
   for i, c in string_ipairs(s)
   do
      if not t[c]
      then
         --mst.d('non-varok', i, c, s)
         return false
      end
   end
   --mst.d('varok', s)
   return true
end

local _my_ascii_table = false

function string_is_ascii(s)
   for i, c in string_ipairs(s)
   do
      local b = string.byte(c)
      if b < 32 or b >= 128
      then
         return false
      end
   end
   return true
end


function string_split_rec(s, delim, ofs, t)
   mst.a(s and delim and ofs and t)
   for i=ofs,#s
   do
      if string.sub(s, i, i+#delim-1) == delim
      then
         t:insert(string.sub(s, ofs, i-1))
         string_split_rec(s, delim, i+#delim, t)
         return
      end
   end
   t:insert(string.sub(s, ofs))
end

function string_split(s, delim)
   mst.a(type(s) == 'string', 'non-string to string_split', s)
   delim = delim or ' '
   mst.a(s, 'undefined argument to string_split', s, delim)

   local t = array:new()
   string_split_rec(s, delim, 1, t)
   return t
end

function string_to_hex(s)
   local t = {}
   for i, c in mst.string_ipairs(s)
   do
      table.insert(t, string.format('%02x', string.byte(c)))
   end
   return table.concat(t)
end

--- table utilities + class

function table_is(t)
   return type(t) == 'table'
end

-- does t contain everything within t1?
-- (using repr_equal)
function table_contains(t, t1)
   mst.a(t and t1, "missing parameters to table_contains")
   for k, v in pairs(t1)
   do
      local v1 = t[k]
      if not repr_equal(v1, v)
      then
         mst.d('differenence in key', k, v1, v)
         return false
      end
   end
   return true
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

-- get count of items within table
function table_count(t)
   c = 0
   for k, v in pairs(t)
   do
      c = c + 1
   end
   return c
end

-- whether table is empty or not
function table_is_empty(t)
   for k, v in pairs(t)
   do
      return false
   end
   return true
end

-- table mapping
function table_map(t, f)
   mst.a(type(t) == "table", "invalid input to table_map", t)
   local r = array:new{}
   for k, v in pairs(t)
   do
      local fr = f(k, v)
      table.insert(r, fr)
   end
   return r
end

-- keys of a table
function table_keys(t)
   return table_map(t, function (k, v)
                       return k
                       end)
end

-- values of a table
function table_values(t)
   return table_map(t, function (k, v)
                       return v
                       end)
end

-- sorted keys of a table
_not_comparable_type = {userdata=true, table=true, boolean=true}

function first_before_cmp(x1, x2)
   local t1 = type(x1)
   local t2 = type(x2)

   if x1 == x2
   then
      return false
   end
   if t1 ~= t2
   then
      return t1 < t2
   end
   if _not_comparable_type[t1]
   then
      x1 = repr(x1)
      x2 = repr(x2)
   end
   return x1 < x2
end

function table_sorted_keys(t)
   -- ugh.. this kinda sucks, if there's userdata keys within :p
   -- ugly workaround
   local keys = table_keys(t)
   table.sort(keys, first_before_cmp)
   return keys
end

-- sorted table pairs
function table_sorted_pairs_iterator(h, k)
   local t, s, sr = unpack(h)

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
      if type(k) == 'string' and string_is_varok(k)
      then
         ks = k
      else
         ks = string.format('[%s]', repr(k, shown))
      end
      table.insert(s, ks .. "=" .. repr(v, shown))
      first = false
   end
   table.insert(s, "}")
   return table.concat(s)
end

function table_clear(t)
   local kl = t:keys()
   for i, k in ipairs(kl)
   do
      t[k] = nil
   end
end

map = create_class{class='map',
                   clear=table_clear,
                   contains=table_contains,
                   copy=table_copy,
                   count=table_count,
                   deep_copy=table_deep_copy,
                   is_empty=table_is_empty,
                   keys=table_keys,
                   map=table_map,
                   repr=table_repr,
                   sorted_keys=table_sorted_keys,
                   sorted_pairs=table_sorted_pairs,
                   values=table_values,
                  }

--- set

function set_map(s, fun)
   a(type(s) == 'table', 'non-table to set_map', t)
   local t = set:new{}
   for k, v in pairs(s)
   do
      fun(k)
      t[k] = true
   end
   return t
end

set = map:new_subclass{class='set',
                       map=set_map,
                      }

function set:insert(o)
   self[o] = true
end

function set:remove(o)
   self[o] = nil
end

function set:intersection(t)
   local r = set:new{}
   for k, _ in pairs(self)
   do
      if t[k]
      then
         r:insert(k)
      end
   end
   return r
end

function set:difference(t)
   local r = set:new{}
   for k, _ in pairs(self)
   do
      if not t[k]
      then
         r:insert(k)
      end
   end
   return r
end

function set:union(t)
   -- in theory, just 2x difference + intersection
   -- but much faster to have dedicated op here
   local r = table_copy(self)
   table_copy(t, r)
   return r
end


-- add 'insert', 'remove' operations'
multimap = map:new_subclass{class='multimap'}
function multimap:insert(k, v)
   self:a(self.class)
   local t = self[k]
   if t == nil
   then
      t = array:new{}
      self[k] = t
   end
   local exists = t:find(v) 
   t:insert(v)
   return not exists
end

function multimap:remove(k, v)
   self:a(self.class)
   local t = self[k]
   mst.a(t, 'nonexistent key', k, v)
   local r = t:remove(v)
   mst.a(r, 'nonexistent value in list', v)
   if #t == 0
   then
      self[k] = nil
   end
   return r
end

function multimap:foreach(f)
   self:a(self.class)
   for k, l in pairs(self)
   do
      for i, v in ipairs(l)
      do
         f(k, v)
      end
   end
end

function multimap:values()
   self:a(self.class)
   local t = array:new()
   self:foreach(function (k, v) t:insert(v) end)
   return t
end

function multimap:count()
   self:a(self.class)
   local c = 0
   self:foreach(function (k, v) c = c + 1 end)
   return c
end

-- do the two objects have same repr?
function repr_equal(o1, o2)
   -- first, stronger equality constraint - if objects
   -- are same, they also have same representation (duh)

   -- may not be true, if we pretend to have string repr on table
   --if type(o1) ~= type(o2) then return false end

   if type(o1) ~= 'userdata' and o1 == o2
   then
      return true
   end

   -- not same objects, fall back to doing actual repr()s (not very
   -- efficient, but correct way to compare some things' equality)
   local s1 = repr(o1)
   local s2 = repr(o2)
   return s1 == s2
end

local _asis_repr = array_to_table{'number', 'function', 'boolean', 'userdata'}

-- python-style repr (works on any object, calls repr() if available,
-- if not, tough
function repr(o, shown)
   local t = type(o)
   if t == 'table'
   then
      shown = shown or {}
      local specific_repr = o.repr
      if specific_repr
      then
         return specific_repr(o, shown)
      end
      if array_is(o)
      then
         return array_repr(o, shown)
      end
      return table_repr(o, shown)
   elseif t == 'string'
   then
      -- if it's ascii string, we do string.format.
      -- string.format results aren't really ascii, though
      if string_is_ascii(o) then
         return string.format('%q', o)
      else
         local t = array:new()
         t:insert('"')
         for i=1,#o
         do
            local c = string.sub(o, i, i)
            if string_is_ascii(c)
            then
               t:insert(c)
            else
               t:insert(string.format('\\%03o', string.byte(c)))
            end
         end
         t:insert('"')
         return t:join()
      end
   elseif t == 'nil'
   then
      return 'nil'
   elseif _asis_repr[t]
   then
      return tostring(o)
   else
      error("unknown type " .. t, 2)
   end
end

-- strtol
function strtol(s, base)
   base = base or 10
   local s = string.lower(s)
   r = 0
   for i, c in mst.string_ipairs(s)
   do
      local v 
      if c >= '0' and c <= '9'
      then
         v = string.byte(c) - string.byte('0')
      elseif c >= 'a' and c <= 'z'
      then
         v = string.byte(c) - string.byte('a') + 10
      else
         return nil, string.format('invalid character at position %d:%s', i, c)
      end
      if v >= base
      then
         return nil, string.format('invalid character at position %d:%s', i, c)
      end
      r = r * base + v
   end
   return r
end

-- count
function count(o)
   if not o
   then
      return 0
   end
   mst.a(type(o) == 'table')
   -- array is different from table; however, table result = array result, so
   -- we just use table_count
   return table_count(o)
end

-- min
function min(...)
   local smallest = nil
   local l = {...}
   array_foreach(l, function (v)
                    if not smallest or v < smallest
                    then
                       smallest = v
                    end
                    end)
   return smallest
end


-- max
function max(...)
   local largest = nil
   local l = {...}
   array_foreach(l, function (v)
                    if not largest or v > largest
                    then
                       largest = v
                    end
                    end)
   return largest
end

function d_xpcall(fun)
   local r = {xpcall(fun,
                     function (...)
                        print(debug.traceback())
                        debug_print('!!! d_xpcall failed', ...)
                     end)}
   table.remove(r, 1)
   return unpack(r)
end

-- bit manipulation
function bitv_is_set_bit(v, n)
   mst.a(v and n)
   if n > 1
   then
      v = math.floor(v / 2^(n-1))
   end
   return v % 2 > 0
end

function bitv_set_bit(v, n)
   mst.a(v and n)
   if not bitv_is_set_bit(v, n)
   then
      local bv = 2^(n-1)
      v = v + bv
   end
   return v
end

function bitv_clear_bit(v, n)
   mst.a(v and n)
   if bitv_is_set_bit(v, n)
   then
      local bv = 2^(n-1)
      v = v - bv
   end
   return v
end

function bitv_xor_bit(v, n)
   mst.a(v and n)
   if bitv_is_set_bit(v, n)
   then
      return bitv_clear_bit(v, n)
   else
      return bitv_set_bit(v, n)
   end
end

function bitv_highest_bit(v)
   mst.a(v)
   local r = math.floor(math.log(v)/math.log(2)) + 1
   mst.d('bitv_highest_bit', v, r)
   return r
end

-- os.execute, which stores results in string
-- return value is the string, or nil + description about the error
-- stderr is NOT redirected by default
function execute_to_string(cmd, redirect_stderr)
   mst.d('system', cmd)

   if redirect_stderr
   then
      cmd = cmd .. " 2>&1"
   end

   local n = os.tmpname()
   cmd = cmd .. " > " .. n
   local r = os.execute(cmd)
   if r ~= 0
   then
      return nil, 'os.execute returned ' .. repr(r)
   end
   local f = io.open(n)
   local d = f:read('*a')
   f:close()
   mst.d('got', d)

   os.remove(n)

   return d
end

-- python-like randint - return random integer in range [a,b],
-- including both endpoints
function randint(a, b)
   mst.a(a <= b)
   local range = b-a
   local v = math.floor(math.random() * (range + 1))
   if v > range
   then
      v = range
   end
   return a + v
end

function array_randindex(t)
   -- pick random item from t, or nil if it's empty
   if #t == 0
   then
      return
   end
   local idx = randint(1, #t)
   mst.a(idx >= 1 and idx <= #t)
   return idx
end

function array_randitem(t)
   local idx = array_randindex(t)
   if idx
   then
      return t[idx]
   end
end

-- event class (used within the baseclass)

-- observer design pattern (Gamma et al).

-- the classic description involves subject <> observer classes we
-- call subject event instead - as what we're tracking are function
-- invocations, in practise (the update() call is actually just call
-- of the event object itself)

-- what we provide is __call-wrapped metatables for both.
-- convenience factors:
--  - sanity checking
--  - 1:n, n:1 relationships (normal pattern has only 1:n)

event = create_class{class='event'}

function event:init()
   self.observers = {}
end

function event:uninit()
   self:a(mst.table_is_empty(self.observers), "observers not gone when event is!")
end

function event:add_observer(o)
   self.observers[o] = true
end

function event:remove_observer(o)
   self:a(self.observers[o], 'observer missing', o)
   self.observers[o] = nil
end

function event:update(...)
   for k, _ in pairs(self.observers)
   do
      k(...)
   end
end

-- event instances' __call should map directly to event.update
getmetatable(event).cmt.__call = event.update

--- cache class (with custom optional lifetime for replies, and
--- external time source)

cache = create_class{class='cache', mandatory={'get_callback'},
                     time_callback=os.time,
                     default_timeout=1}

function cache:init()
   self:clear()
end

function cache:clear()
   self.map = map:new{}
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
   local now = self.time_callback()

   self:d('get', now, valid, k, value)

   if now <= valid
   then
      return value
   end
   return self:create(k)
end

function cache:create(k)
   local v, t = self.get_callback(k)
   self:set(k, v, t)
   return v
end

function cache:set(k, v, t)
   self.map[k] = nil
   t = t or (v and self.positive_timeout) or self.negative_timeout or self.default_timeout
   local now = self.time_callback()
   self.map[k] = {t + now, v}
end

-- string_find_one
-- try to string_find among string with multiple pattern + action functions
-- to run out of functions is fatal error => add nop handler to end if desirable
function string_find_one(s, ...)
   local l = {...}
   for i=1,#l,2
   do
      local pat = l[i]
      local act = l[i+1]
      local r = {string.find(s, pat)}
      if #r >= 2
      then
         if act
         then
            return act(unpack(array_slice(r, 3)))
         end
         return
      end
   end
   mst.a(false, 'no match for string', s, l)
end
