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
-- Last modified: Tue Jan  8 15:04:01 2013 mstenber
-- Edit time:     205 min
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
require 'ipv4s'
require 'ipv6s'

module(..., package.seeall)

local abstract_base = codec.abstract_base
local abstract_data = codec.abstract_data
local cursor_has_left = codec.cursor_has_left

CLASS_IN=1
CLASS_ANY=255

-- RFC1035
TYPE_A=1
TYPE_NS=2
TYPE_CNAME=5
TYPE_PTR=12
TYPE_HINFO=13
TYPE_MX=15
TYPE_TXT=16

-- RFC3596
TYPE_AAAA=28

-- RFC2782
TYPE_SRV=33

-- RFC4304
TYPE_RRSIG=46
TYPE_NSEC=47
TYPE_DNSKEY=48


TYPE_ANY=255


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


--- actual data classes

dns_header = abstract_data:new{class='dns_header',
                               format='id:u2 [2|qr:b1 opcode:u4 aa:b1 tc:b1 rd:b1 ra:b1 z:u1 ad:b1 cd:b1 rcode:u4] qdcount:u2 ancount:u2 nscount:u2 arcount:u2',
                               header_default={id=0,
                                               qr=false,
                                               opcode=0,
                                               aa=false,
                                               tc=false,
                                               rd=false,
                                               ra=false,
                                               z=0,
                                               -- ad, cd defined in RFC2535
                                               ad=false,
                                               cd=false,

                                               rcode=0,
                                               qdcount=0,
                                               ancount=0,
                                               nscount=0,
                                               arcount=0,}
                              }

dns_query = abstract_data:new{class='dns_query',
                              format='qtype:u2 [2|qclass:u15 qu:b1]',
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


rdata_srv = abstract_data:new{class='rdata_srv',
                              format='priority:u2 weight:u2 port:u2',
                              header_default={priority=0,
                                              weight=0,
                                              port=0}}

function rdata_srv:try_decode(cur, context)
   -- first off, get the base struct
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return nil, err end

   -- and then 'target', which is FQDN
   local n, err = try_decode_name_rec(cur, context)
   if not n then return nil, err end
   
   o.target = n
   return o
end

function rdata_srv:do_encode(o, context)
   local t = encode_name_rec(o.target, context)
   -- ugh, but oh well :p
   return abstract_data.do_encode(self, o) .. table.concat(t)
end

rdata_nsec = abstract_base:new{class='rdata_nsec'}

function rdata_cursor_has_left(cur, n)
   if cur.endpos 
   then
      return cur.pos + n <= cur.endpos
   end
   return cursor_has_left(cur, n)
end

function rdata_nsec:try_decode(cur, context)
   -- two things - next domain name (ndn)
   local n, err = try_decode_name_rec(cur, context)
   if not n then return nil, err end
   
   -- and bitmap
   --local t = mst.set:new{}
   local t = mst.array:new{}
   while rdata_cursor_has_left(cur, 2)
   do
      -- block #
      local block_offset = string.byte(cur:read(1))
      -- bytes
      local block_bytes = string.byte(cur:read(1))
      self:d('reading', block_offset, block_bytes)
      if not rdata_cursor_has_left(cur, block_bytes)
      then
         return nil, string.format('decode ended mid-way (no %d bytes left)',
                                   block_bytes)
      end
      for i=1,block_bytes
      do
         local c = cur:read(1)
         local b = string.byte(c)
         -- XXX - some day would be nice to have network order
         -- independent decode here. oh well. 
         for j=8,1,-1
         do
            if mst.bitv_is_set_bit(b, j)
            then
               t:insert(256 * block_offset +
                        8 * (i - 1) + 
                        (8 - j))
            end
         end
      end
   end
   return {ndn=n, bits=t}
end

function iterate_modulo_ranges(bits, modulo, f, st, en)
   local st = st or 1
   local nbits = #bits
   local en = en or nbits

   local i = st
   while i <= en
   do
      local j = i
      local v = bits[i]
      local mr = math.floor(v / modulo)
      mst.d('finding subblock', i, en, modulo, v, mr)
      while (j+1) <= en and math.floor(bits[j+1] / modulo) == mr
      do
         j = j + 1
      end
      f(mr, i, j)
      i = j + 1
      mst.d('i now', i)
   end
end


function rdata_nsec:do_encode(o, context)
   mst.a(o, 'no object given to encode?!?')
   mst.a(o.ndn)
   local n = encode_name_rec(o.ndn, context)
   local t = {}
   -- encoding of the bits is bit more complex
   local bits = o.bits
   table.sort(bits)
   -- first off, try to get the 256-bit blocks, and deal with them
   iterate_modulo_ranges(bits, 256,
                         function (mr, i1, j1)
                            --mst.d('handling', mr)
                            local t0 = {}
                            iterate_modulo_ranges(bits, 8,
                                                  function (br, i2, j2)
                                                     br = br % 32
                                                     while #t0 < br
                                                     do
                                                        table.insert(t0, 0)
                                                     end
                                                     local v = 0
                                                     for i=i2,j2
                                                     do
                                                        local b=bits[i]
                                                        v = mst.bitv_set_bit(v, 8-b%8)
                                                     end
                                                     mst.d('produced', v)
                                                     table.insert(t0, v)
                                                  end, i1, j1)
                            table.insert(t, string.char(mr, #t0, unpack(t0)))
                         end)
   mst.array_extend(n, t)
   --mst.d('concatting', n)
   return table.concat(n)
end


local rtype_map = {[TYPE_PTR]={
                      encode=function (self, o, context)
                         mst.a(o.rdata_ptr)
                         return table.concat(encode_name_rec(o.rdata_ptr, context))
                      end,
                      decode=function (self, o, cur, context)
                         local name, err = try_decode_name_rec(cur, context)
                         if not name then return nil, err end
                         o.rdata_ptr = name
                         return true
                      end,
                            },
                   [TYPE_A]={
                      encode=function (self, o, context)
                         mst.a(o.rdata_a)
                         local b = ipv4s.address_to_binary_address(o.rdata_a)
                         mst.a(#b == 4, 'encode error')
                         return ipv4s.address_to_binary_address(o.rdata_a)
                      end,
                      decode=function (self, o, cur, context)
                         if not rdata_cursor_has_left(cur, 4)
                         then
                            return nil, 'not enough rdata (4)'
                         end
                         local b = cur:read(4)
                         o.rdata_a = ipv4s.binary_address_to_address(b)
                         return true
                      end,
                   },
                   [TYPE_AAAA]={
                      encode=function (self, o, context)
                         mst.a(o.rdata_aaaa)
                         local b = ipv6s.address_to_binary_address(o.rdata_aaaa)
                         mst.a(#b == 16, 'encode error', o)
                         return b
                      end,
                      decode=function (self, o, cur, context)
                         if not rdata_cursor_has_left(cur, 16)
                         then
                            return nil, 'not enough rdata (16)'
                         end
                         local b = cur:read(16)
                         local s = ipv6s.binary_address_to_address(b)
                         o.rdata_aaaa = s
                         return s
                      end,
                   },
}

local function add_rtype_decoder(type, cl, dname)
   rtype_map[type] = {
      encode=function (self, o, context)
         return cl:encode(o[dname], context)
      end,
      decode=function (self, o, cur, context)
         cur.endpos = cur.pos + o.rdlength
         local r, err = cl:decode(cur, context)
         cur.endpos = nil
         if not r then return nil, err end
         o[dname] = r
         return true
      end,
   }
end

add_rtype_decoder(TYPE_SRV, rdata_srv, 'rdata_srv')
add_rtype_decoder(TYPE_NSEC, rdata_nsec, 'rdata_nsec')

dns_rr = abstract_data:new{class='dns_rr',
                           format='rtype:u2 [2|cache_flush:b1 rclass:u15] ttl:u4 rdlength:u2',
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

   local handler = rtype_map[r.rtype]
   if handler 
   then 
      self:d('using handler')
      self:d('using handler', cur)
      local ok, err = handler:decode(r, cur, context)
      if not ok then return nil, err end
   else
      local l = r.rdlength
      self:d('default rdata handling (as-is)', r.rtype, l)
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
   end
   return r
end

function dns_rr:do_encode(o, context)
   local t = encode_name_rec(o.name, context)
   local handler = rtype_map[o.rtype or -1]
   if handler 
   then 
      o.rdata, err = handler:encode(o, context) 
      if not o.rdata then return nil, err end
   end
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
