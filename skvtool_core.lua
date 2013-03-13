#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skvtool_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Feb 25 12:21:09 2013 mstenber
-- Last modified: Wed Mar 13 11:50:00 2013 mstenber
-- Edit time:     60 min
--

-- this is the 'utility' functionality of skvtool, which is used by
-- skvtool.lua. The main point of this is to be able to write unit
-- tests for the functionality herein, while the skvtool itself is
-- inherently not really conveniently unit testable due to it's UI
-- being on CLI tool (sure, I _could_ write set of shell scripts, but
-- I rather not)

require 'mst'
local json = require "dkjson"

module(..., package.seeall)

stc = mst.create_class{class='stc',
                       mandatory={'skv'}}

function stc:init()
   -- nops, but for documentation purposes..
   self.read_dirty = false

   self.wcache = nil
end

function stc:repr_data()
   return mst.repr{wcc=(self.wcache and mst.table_count(self.wcache) or 0)}
end

-- public API start

function stc:process_key(str)
   local k, v = unpack(mst.string_split(str, '=', 2))
   k = mst.string_strip(k)
   if v
   then
      v = mst.string_strip(v)
      self:handle_set(k, v)
   else
      k = str
      v = self:get(str)
      self:output(string.format("%s=%s", k, self:encode_value_to_string(v)))
   end
end

function stc:process_keys(l)
   for i, str in ipairs(l)
   do
      self:process_key(str)
   end
   self:d('process_keys done')
   self:wait_in_sync()
end

function stc:list_all(encode)
   if not encode
   then
      encode = function (s)
         return self:encode_value_to_string(s)
      end
   end
   local st = self:get_state_map()
   self:d('dumping entries', mst.table_count(st))
   local kl = mst.table_keys(st)
   table.sort(kl)
   for i, k in ipairs(kl)
   do
      local v = st[k]
      self:output(string.format("%s=%s", k, encode(v)))
   end
end

-- private functionality

function stc:handle_set(k, v)
   mst.a(v, 'missing value')
   self:d('.. setting', k, v)
   v = self:decode_value_from_string(v)
   -- let's see if the key terminates with + or -; 
   -- in that case, this is list operation instead
   if mst.string_endswith(k, '+')
   then
      self:handle_list_add(string.sub(k, 1, #k-1), v)
      return
   end
   if mst.string_endswith(k, '-')
   then
      self:handle_list_delete(string.sub(k, 1, #k-1), v)
      return
   end

   self:set(k, v)
   self:d('.. done')
end

function stc:handle_list_add(k, v)
   k = mst.string_strip(k)
   local l = self:get(k)
   if not l
   then
      self:set(k, {v})
      return
   end
   -- otherwise, have to make copy of list, add one item, and set it.. ugh
   self:d('adding to', l)

   l = mst.table_copy(l)
   table.insert(l, v)
   self:set(k, l)
end

function stc:handle_list_delete(k, v)
   k = mst.string_strip(k)
   local l = self:get(k)
   if not l
   then
      return
   end
   l = mst.array_filter(l, function (o)
                           return not mst.table_contains(o, v)
                           end
                       )
   self:set(k, l)
end

function stc:decode_value_from_string(v)
   local o, err = json.decode(v)
   if not o
   then
      self:d('decode failed - fallback to verbatim', err)
      return v
   end
   return o
end

function stc:encode_value_to_string(v)
   --return mst.repr(v)
   return json.encode(v)
end

-- get, set, wait_in_sync - responsibility of the caller, but
-- by default we pass them to local 'skv' object'

function stc:get_state_map()
   local h2 = self.skv:get_combined_state()
   if not self.wcache then return h2 end

   -- highly inefficient, oh well
   local h = {}
   
   for k, v in pairs(h2)
   do
      h[k] = v
   end

   for k, v in pairs(self.wcache)
   do
      h[k] = v
   end
   return h
end

function stc:empty_wcache()
   -- nothing in write cache -> we're good
   if not self.wcache then return end
   for k, v in pairs(self.wcache)
   do
      self:d('calling set', k, v)
      self.skv:set(k, v)
   end
   self.wcache = nil
   return true
end

function stc:wait_in_sync()
   if not self:empty_wcache() then return  end
   self:d('.. waiting for (write) sync')
   if not self.disable_wait
   then
      self.skv:wait_in_sync()
   end
   return true
end

function stc:set(k, v)
   self:d('stc:set', k, v)
   if not v
   then
      -- can't store in write cache, have to flush immediately. oh well.
      self:wait_in_sync()
      self:d('calling set', k, v)
      self.skv:set(k, v)
      return
   end
   self.wcache = self.wcache or {}
   self.wcache[k] = v
   self:d('stc:set done')
end

function stc:get(k)
   -- first off, try to get from pending write cache (it's more recent)
   local v = self.wcache and self.wcache[k]
   -- failing that, just get it from skv
   return v or self.skv:get(k)
end

-- this is stubbed mostly for testability - in test case,
-- we probably do not want to output to print but instead .. elsewhere.
function stc:output(s)
   print(s)
end
