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
-- Last modified: Wed Jun 19 14:14:31 2013 mstenber
-- Edit time:     45 min
--

require 'dns_const'
require 'codec'

module(..., package.seeall)


local cursor_has_left = codec.cursor_has_left

--- general utilities to deal with FQDN en/decode
function _try_decode_name_rec(cur, h, n)
   --mst.d('try_decode_name_rec', h)
   if not cursor_has_left(cur, 1)
   then
      return nil, 'out of bytes (reading name)'
   end
   local npos = cur.pos
   local b0 = cur:read(1)
   local v = string.byte(b0)
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
      if not h.disable_decode_names
      then
         local v2 = string.byte(b)
         local ofs = v * 256 + v2
         mst.a(h, 'h not set when decoding name with message compression')
         if not h[ofs]
         then
            --mst.d('eek - about to blow up - dump', h, 'missing offset', ofs)
            return nil, 'unable to find value at ofs ' .. tostring(ofs)
         end
         local on, oofs = unpack(h[ofs])
         -- 'other name' = on. 'oofs' = which entry to start at copying
         for i=oofs,#on
         do
            n[#n+1] = on[i]
         end
         --mst.d('found from', ofs, mst.array_slice(n, oofs))
      else
         n[#n+1] = {b0, b}
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
   b = cur:read(v)
   -- store position to hash for message compression use
   if h
   then
      --mst.d('adding', npos, #n+1, b)
      h[npos] = {n, #n + 1}
   end
   n[#n+1] = b
   -- and recurse (can't end on non-0 string)
   return _try_decode_name_rec(cur, h, n)
end

function try_decode_name(cur, h)
   return _try_decode_name_rec(cur, h, {})
end

function _encode_name_rec(n, h, t, ofs)
   mst.a(type(n) == 'table', 'non-table given to encode_name_rec', n)
   -- handle eof
   if ofs > #n
   then
      table.insert(t, string.char(0))
      if h
      then
         h.pos = h.pos + 1
      end
      return t
   end
   local v = n[ofs]

   -- name compression handling
   if h and h.ns
   then
      local ns = h.ns
      -- figure if this array(sub)string exists
      local sn = n
      if ofs > 1
      then
         sn = mst.array_slice(n, ofs)
      end
      local ofs2
      ns:iterate_rrs_for_ll(sn, 
                            function (o)
                               ofs2 = o.pos
                            end)
      if ofs2
      then
         --mst.d('found at', ofs2, sn)
         local o1 = math.floor(ofs2/256)
         local o2 = ofs2%256
         table.insert(t, string.char(64 + 128 + o1))
         table.insert(t, string.char(o2))
         h.pos = h.pos + 2
         return t
      end
      --mst.d('inserting', h.pos, sn)
      -- store the current position as where we can be found
      ns:insert_raw{name=sn, pos=h.pos}
      -- and update the position with the encoded data length
      h.pos = h.pos + 1 + #v
   end
   mst.a(#v > 0, 'we do not support empty labels in middle!')
   mst.a(#v < 64, 'too long label', v)
   table.insert(t, string.char(#v))
   table.insert(t, v)
   return _encode_name_rec(n, h, t, ofs+1)
end

function encode_name(n, h)
   local t = {}
   return _encode_name_rec(n, h, t, 1)
end

function try_encode_name(n, h)
   mst.a(n, 'trying to encode nil name')
   mst.a(type(n) == 'table', 'wrong type name', type(n), n)

   -- XXX - RFC1035 is not very clear about interaction between name
   -- compression and maximum name length. here we check
   -- _uncompressed_ length, even if h and h.ns is provided (=name
   -- compression is enabled)

   local cnt = 1 -- final 0 label's length
   for i, v in ipairs(n)
   do
      if #v > dns_const.MAXIMUM_LABEL_SIZE
      then
         return nil, 'too long label ' .. mst.repr(n)
      end
      cnt = cnt + 1 + #v
   end
   if cnt > dns_const.MAXIMUM_NAME_SIZE
   then
      return nil, 'too long name ' .. mst.repr(n)
   end
   return encode_name(n, h)
end
