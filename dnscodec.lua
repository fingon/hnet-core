#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnscodec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 30 11:15:52 2012 mstenber
-- Last modified: Fri Nov 30 12:27:50 2012 mstenber
-- Edit time:     37 min
--

-- Functionality for en-decoding various DNS structures;

-- - DNS RR
-- - DNS query
-- - DNS message

-- Only really tricky part is the message compression; we do it by
-- having a local state about the labels' locations while
-- uncompressing. When compressing, we have hash_set which contains
-- all dumped label substrings and their locations, and we pick one
-- whenever we find something that matches.

-- Internally, FQDN is stored WITHOUT the final terminating 'empty'
-- label. There is no point, as we're storing the label lists in Lua
-- arrays, and we can just assume it's there, always.

-- NOTE: Current message compression (decoding) algorithm works only
-- in RFC1035 compliant format => has to be _prior_ occurence of the
-- name. If it's subsequent one, all bets are off..

-- XXX - implement name compression for encoding too!

require 'codec'

module(..., package.seeall)

local abstract_data = codec.abstract_data

dns_rr = abstract_data:new_subclass{class='dns_rr',
                                    format='rtype:u2 rclass:u2 ttl:u4 rdlength:u2',
                                    header_default={rtype=0,
                                                    rclass=1,
                                                    ttl=0,
                                                    rdlength=0,},
                                   }

function try_decode_name_rec(cur, h, n)
   n = n or {}
   if not codec.cursor_has_left(cur, 1)
   then
      return nil, 'out of bytes (reading name)'
   end
   local b = cur:read(1)
   local v = string.byte(b)
   if v >= 64
   then
      if not codec.cursor_has_left(cur, 1)
      then
         return nil, 'out of bytes (reading compression offset)'
      end
      if v < (64+128)
      then
         return nil, 'invalid high bits in name label'
      end
      v = v - 64 - 128
      local b = cur:read(1)
      local v2 = string.byte(b)
      local ofs = v * 256 + v2
      mst.a(h, 'h not set when decoding name with message compression')
      if not h[ofs]
      then
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
   if not codec.cursor_has_left(cur, v)
   then
      return nil, 'out of bytes (label body)'
   end
   -- store position to hash for message compression use
   if h
   then
      h[cur.pos-1] = {n, #n + 1}
   end
   -- read the actual string
   b = cur:read(v)
   n[#n+1] = b
   -- and recurse (can't end on non-0 string)
   return try_decode_name_rec(cur, h, n)
end

function dns_rr:try_decode()
   -- in RR, the name is _first_ part. So we decode that, then the
   -- fixed-length fields, and then finally leftover rdata
   
   local r = {}

   local name, err = try_decode_name_rec(self._cur, self.h)
   if not name then return nil, err end
   r.name = name

   local cur = self._cur


   local o, err = abstract_data.try_decode(self)
   if not o then return nil, err end

   -- copy the header fields
   mst.table_copy(o, r)

   local l = r.rdlength
   if l > 0
   then
      if not self:has_left(l)
      then
         return nil, 'not enough bytes for body'
      end
      r.rdata = cur:read(l)
   else
      r.rdata = ''
   end
   return r
end

-- message compression is optional => we skip it for the time being
function encode_name_rec(n, h)
   local t = {}
   for i, v in ipairs(n)
   do
      mst.a(#v > 0, 'we do not support empty labels in middle!')
      table.insert(t, string.char(#v))
      table.insert(t, v)
   end
   table.insert(t, string.char(0))
   return t
end

function dns_rr:do_encode(o)
   local t = encode_name_rec(o.name, self.h)
   o.rdlength = #o.rdata
   table.insert(t, abstract_data.do_encode(self, o))
   table.insert(t, o.rdata)
   return table.concat(t)
end


