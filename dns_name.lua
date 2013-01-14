#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_name.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jan 14 13:08:37 2013 mstenber
-- Last modified: Mon Jan 14 13:12:46 2013 mstenber
-- Edit time:     1 min
--

require 'codec'

module(..., package.seeall)

local cursor_has_left = codec.cursor_has_left

--- general utilities to deal with FQDN en/decode

function try_decode_name_rec(cur, h, n)
   n = n or {}
   if not cursor_has_left(cur, 1)
   then
      return nil, 'out of bytes (reading name)'
   end
   local b = cur:read(1)
   local v = string.byte(b)
   if v >= 64
   then
      if not cursor_has_left(cur, 1)
      then
         return nil, 'out of bytes (reading compression offset)'
      end
      if v < (64+128)
      then
         return nil, 'invalid high bits in name label ' .. tostring(v)
      end
      v = v - 64 - 128
      local b = cur:read(1)
      local v2 = string.byte(b)
      local ofs = v * 256 + v2
      mst.a(h, 'h not set when decoding name with message compression')
      if not h[ofs]
      then
         mst.d('eek - about to blow up - dump', h, 'missing offset', ofs)
         return nil, 'unable to find value at ofs ' .. tostring(ofs)
      end
      local on, oofs = unpack(h[ofs])
      -- 'other name' = on. 'oofs' = which entry to start at copying
      for i=oofs,#on
      do
         n[#n+1] = on[i]
      end
      return n
   end
   -- let's see if it's the end
   if v == 0
   then
      return n
   end
   -- not end -> have to have the bytes
   if not cursor_has_left(cur, v)
   then
      return nil, 'out of bytes (label body)'
   end
   -- read the actual string
   local pos = cur.pos
   b = cur:read(v)
   -- store position to hash for message compression use
   if h
   then
      mst.d('adding', pos-1, #n+1, b)
      h[pos-1] = {n, #n + 1}
   end
   n[#n+1] = b
   -- and recurse (can't end on non-0 string)
   return try_decode_name_rec(cur, h, n)
end

-- message compression is optional => we skip it for the time being
function encode_name_rec(n, h)
   local t = {}
   mst.a(type(n) == 'table', 'non-table given to encode_name_rec', n)
   for i, v in ipairs(n)
   do
      mst.a(#v > 0, 'we do not support empty labels in middle!')
      table.insert(t, string.char(#v))
      table.insert(t, v)
   end
   table.insert(t, string.char(0))
   return t
end


