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
-- Last modified: Mon Feb 25 13:37:58 2013 mstenber
-- Edit time:     28 min
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

stc = mst.create_class{class='stc'}

function stc:init()
   self.did_set = false
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
      self:wait_in_sync_if_needed()
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

   self:wait_in_sync_if_needed()
end

function stc:list_all()
   self:wait_in_sync_if_needed()
   local st = self.skv:get_combined_state()
   self:d('dumping entries', mst.table_count(st))
   local kl = mst.table_keys(st)
   table.sort(kl)
   for i, k in ipairs(kl)
   do
      local v = st[k]
      self:output(string.format("%s=%s", k, self:encode_value_to_string(v)))
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
   self.did_set = true
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

function stc:wait_in_sync_if_needed()
   if not self.did_set then return end
   self:d('.. waiting for sync')
   self:wait_in_sync()
   self:d('.. done')
   self.did_set = false
end

-- get, set, wait_in_sync - responsibility of the caller, but
-- by default we pass them to local 'skv' object'
function stc:set(k, v)
   self.skv:set(k, v)
end

function stc:get(k)
   return self.skv:get(k)
end

function stc:wait_in_sync()
   self.skv:wait_in_sync()
end

-- this is stubbed mostly for testability - in test case,
-- we probably do not want to output to print but instead .. elsewhere.
function stc:output(s)
   print(s)
end
