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
-- Last modified: Fri Nov 30 14:24:19 2012 mstenber
-- Edit time:     94 min
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

-- XXX - add sub-type decoding (PTR, SRV); we don't 'do' expansion
-- from unknown record types (although perhaps we should?)

-- XXX - implement name compression for encoding too!

require 'codec'

module(..., package.seeall)

local abstract_data = codec.abstract_data
local cursor_has_left = codec.cursor_has_left

CLASS_IN=1

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
   for i, v in ipairs(n)
   do
      mst.a(#v > 0, 'we do not support empty labels in middle!')
      table.insert(t, string.char(#v))
      table.insert(t, v)
   end
   table.insert(t, string.char(0))
   return t
end


--- actual data classes

dns_header = abstract_data:new{class='dns_header',
                               format='id:u2 [2|qr:b1 opcode:u4 aa:b1 tc:b1 rd:b1 ra:b1 z:u3 rcode:u4] qdcount:u2 ancount:u2 nscount:u2 arcount:u2',
                               header_default={id=0,
                                               qr=false,
                                               opcode=0,
                                               aa=false,
                                               tc=false,
                                               rd=false,
                                               ra=false,
                                               z=0,
                                               rcode=0,
                                               qdcount=0,
                                               ancount=0,
                                               nscount=0,
                                               arcount=0,}
                              }

dns_query = abstract_data:new{class='dns_query',
                              format='qtype:u2 qclass:u2',
                              header_default={qtype=0, qclass=CLASS_IN},
                             }

function dns_query:try_decode(cur, context)
   -- in query, the name is _first_ part. So we decode that, then the
   -- fixed-length fields.
   
   local r = {}

   local name, err = try_decode_name_rec(cur, context)
   if not name then return nil, err end


   local o, err = abstract_data.try_decode(self, cur)
   if not o then return nil, err end

   -- copy the name to the record
   o.name = name

   return o
end

function dns_query:do_encode(o, context)
   local t = encode_name_rec(o.name, context)
   table.insert(t, abstract_data.do_encode(self, o))
   return table.concat(t)
end



dns_rr = abstract_data:new{class='dns_rr',
                           format='rtype:u2 rclass:u2 ttl:u4 rdlength:u2',
                           header_default={rtype=0,
                                           rclass=CLASS_IN,
                                           ttl=0,
                                           rdlength=0,},
                          }

function dns_rr:try_decode(cur, context)
   -- in RR, the name is _first_ part. So we decode that, then the
   -- fixed-length fields, and then finally leftover rdata
   
   local r = {}

   local name, err = try_decode_name_rec(cur, context)
   if not name then return nil, err end
   r.name = name

   local o, err = abstract_data.try_decode(self, cur)
   if not o then return nil, err end

   -- copy the header fields
   mst.table_copy(o, r)

   local l = r.rdlength
   if l > 0
   then
      if not cursor_has_left(cur, l)
      then
         return nil, 'not enough bytes for body'
      end
      r.rdata = cur:read(l)
   else
      r.rdata = ''
   end
   return r
end

function dns_rr:do_encode(o, context)
   local t = encode_name_rec(o.name, context)
   o.rdlength = #o.rdata
   table.insert(t, abstract_data.do_encode(self, o))
   table.insert(t, o.rdata)
   return table.concat(t)
end


-- dns message - container for everything

-- assumption:
-- h = header, qd = question, an = answer, ns = authority, ar = additional

dns_message = codec.abstract_base:new{class='dns_message', 
                                      lists={
                                         {'qd', dns_query},
                                         {'an', dns_rr},
                                         {'ns', dns_rr},
                                         {'ar', dns_rr},
                                      }
                                     }

function dns_message:repr_data()
   return ''
end

function dns_message:do_encode(o)
   local h = o.h or {}
   for i, v in ipairs(self.lists)
   do
      np, cl = unpack(v)
      h[np .. 'count'] = o[np] and #o[np] or 0
   end
   local t = mst.array:new{}

   -- initially encode header
   local r, err = dns_header:encode(h)
   if not r
   then
      return nil, err
   end

   t:insert(r)

   -- then, handle each sub-list
   for i, v in ipairs(self.lists)
   do
      np, cl = unpack(v)
      --self:d('considering', np, o[np])
      for i, v in ipairs(o[np] or {})
      do
         --self:d('encoding', np, i)

         local r, err = cl:encode(v)
         if not r then return nil, err end
         t:insert(r)
      end
   end

   -- finally concat result together and return it
   return table.concat(t)
end
                                      
function dns_message:try_decode(cur)
   local o = {}

   -- grab header
   local h, err = dns_header:decode(cur)
   if not h then return nil, err end

   o.h = h

   -- used to store message compression offsets
   local context = {}

   -- then handle each list
   for i, v in ipairs(self.lists)
   do
      np, cl = unpack(v)
      local l = {}
      local cnt = h[np .. 'count']
      for i=1,cnt
      do
         local o, err = cl:decode(cur, context)
         self:d('got', np, i, o)
         if not o then return nil, err end
         l[#l+1] = o
      end
      o[np] = l
   end
   return o
end
