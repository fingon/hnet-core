#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_codec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 30 11:15:52 2012 mstenber
-- Last modified: Mon Feb 18 12:19:06 2013 mstenber
-- Edit time:     274 min
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
require 'dns_const'
require 'dns_name'
require 'dns_rdata'
require 'dns_db'

module(..., package.seeall)

local abstract_base = codec.abstract_base
local abstract_data = codec.abstract_data
local cursor_has_left = codec.cursor_has_left
local encode_name_rec = dns_name.encode_name_rec
local try_decode_name_rec = dns_name.try_decode_name_rec

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
                              format='qtype:u2 [2|qu:b1 qclass:u15]',
                              header_default={qtype=0, qclass=dns_const.CLASS_IN},
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
                           format='rtype:u2 [2|cache_flush:b1 rclass:u15] ttl:u4 rdlength:u2',
                           header_default={rtype=0,
                                           rclass=dns_const.CLASS_IN,
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

   local handler = dns_rdata.rtype_map[r.rtype]
   if handler 
   then 
      --self:d('using handler', cur)
      local ok, err = handler:decode(r, cur, context)
      if not ok then return nil, err end
   else
      local l = r.rdlength
      --self:d('default rdata handling (as-is)', r.rtype, l)
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

function dns_rr:produce_rdata(o, context)
   local handler = dns_rdata.rtype_map[o.rtype or -1]
   if handler 
   then 
      --mst.d('calling encode', context.pos, o)
      -- update pos s.t. the rdata encoder will have correct
      -- position to start at..
      if context
      then
         context.pos = context.pos + self.header_length
      end
      return handler:encode(o, context) 
   end
   return o.rdata
end

function dns_rr:do_encode(o, context)
   mst.a(type(o) == 'table')
   local t = encode_name_rec(o.name, context)
   o.rdata = self:produce_rdata(o, context)
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

   -- context for storing the encoded offsets of names
   local pos = #r
   local context = {pos=pos}
   context.ns = dns_db.ns:new{}

   -- then, handle each sub-list

   for i, v in ipairs(self.lists)
   do
      np, cl = unpack(v)
      --self:d('considering', np, o[np])
      for i, v in ipairs(o[np] or {})
      do
         --self:d('encoding', np, i)
         -- store the current position where this stuff _starts_
         local r, err = cl:encode(v, context)
         if not r then return nil, err end
         t:insert(r)
         -- sub-encoders may have played with the position.
         -- therefore, we update the 'master copy' of pos here
         pos = pos + #r
         context.pos = pos
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
      local l = mst.array:new{}
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
