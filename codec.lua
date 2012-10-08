#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: codec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Sep 27 13:46:47 2012 mstenber
-- Last modified: Mon Oct  8 12:46:42 2012 mstenber
-- Edit time:     145 min
--

-- object-oriented codec stuff that handles encoding and decoding of
-- the network packets (or their parts)

-- key ideas

-- - employ vstruct for heavy lifting

-- - nestable (TLV inside LSA inside OSPF, for example)

-- - extensible

local mst = require 'mst'
local vstruct = require 'vstruct'
local ipv6s = require 'ipv6s'

module(..., package.seeall)

AC_TLV_RHF=1
AC_TLV_USP=2
AC_TLV_ASP=3

MINIMUM_AC_TLV_RHF_LENGTH=32


--mst.enable_debug = true

abstract_data = mst.create_class{class='abstract_data'}

--- abstract_data baseclass

function abstract_data:init()
   if not self.header
   then
      --mst.d('init header', self.format)
      self:a(self.format, "no header AND no format?!?")
      self.header=vstruct.compile('<' .. self.format)
   end
   if not self.header_length
   then
      --mst.d('init header_length', self.header, self.header_default)
      self:a(self.header, 'header missing')
      self:a(self.header_default, 'header_default missing')
      self.header_length = #self.header.pack(self.header_default)
   end
end

function abstract_data:repr_data()
   return mst.repr{format=self.format, header_length=self.header_length, header_default=self.header_default}
end

function abstract_data:decode(cur)
   if type(cur) == 'string'
   then
      cur = vstruct.cursor(cur)
   end
   local pos = cur.pos
   local o, err = self:try_decode(cur)
   if o
   then
      return o
   end
   -- decode failed => restore cursor to wherever it was
   cur.pos = pos
   return nil, err
end

function abstract_data:try_decode(cur)
   self:d('try_decode', cur)

   self:a(self)

   if not has_left(cur, self.header_length) 
   then
      return nil, string.format('not enough left for header (%d<%d+%d)',
                                #cur.str, self.header_length, cur.pos)
   end
   local o = self.header.unpack(cur)
   return o
end
                                 
function abstract_data:do_encode(o)
   -- copy in defaults if they haven't been filled in by someone yet
   if self.header_default
   then
      for k, v in pairs(self.header_default)
      do
         if not o[k]
         then
            o[k] = v
         end
      end
   end
   
   local r = self.header.pack(o)
   --mst.d('do_encode', mst.string_to_hex(r))
   return r
end

function abstract_data:encode(o)
   self:d('encode', o)

   self:a(self.header, 'header missing - using class method instead of instance?')

   -- work on shallow copy
   o = mst.table_copy(o)

   -- call do_encode to do real things
   return self:do_encode(o)
end

function has_left(cur, n)
   -- cur.pos is indexed by 'last read' position => 0 = start of file
   mst.a(type(n) == 'number')
   mst.a(type(cur) == 'table')

   return (#cur.str - cur.pos) >= n
end


--- ac_tlv _instance_ of abstract_data (but we override class for debugging)

ac_tlv = abstract_data:new_subclass{class='ac_tlv',
                                    format='type:u2 length:u2',
                                    mandatory={'tlv_type'},
                                   }

function ac_tlv:init()
   -- look at header_default - if type not set, child hasn't bothered..
   if not self.header_default
   then
      self.header_default = {type=self.tlv_type, length=0}
   end

   -- call superclass init
   abstract_data.init(self)
end

function ac_tlv:try_decode(cur)
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return o, err end
   -- then make sure there's also enough space left for the body
   if not has_left(cur, o.length) then return nil, 'not enough for body' end
   -- check tlv_type
   if self.tlv_type and o.type ~= self.tlv_type 
   then 
      return nil, string.format("wrong type - expected %d, got %d", self.tlv_type, o.type)
   end
   o.body = cur:read(o.length)
   self:a(#o.body == o.length)
   return o
end

function ac_tlv:do_encode(o)
   -- must be a subclass which has tlv_type set!
   self:a(self.tlv_type, 'self.tlv_type not set')
   o.length = #o.body
   return abstract_data.do_encode(self, o) .. o.body
end

--- prefix_body
prefix_body = abstract_data:new{class='prefix_body', 
                                format='prefix_length:u1 r1:u1 r2:u1 r3:u1',
                                header_default={prefix_length=0, r1=0, r2=0, r3=0}}

function prefix_body:try_decode(cur)
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return o, err end
   s = math.floor((o.prefix_length + 31) / 32)
   s = s * 4
   if not has_left(cur, s) then return nil, 'not enough for prefix' end
   r = cur:read(s)
   o.prefix = ipv6s.binary_to_ascii(r)
   return o
end

local _null = string.char(0)

function prefix_body:do_encode(o)
   mst.a(o.prefix, 'prefix missing', o)
   mst.a(o.prefix_length, 'prefix_length missing', o)

   b = ipv6s.ascii_to_binary(o.prefix)
   s = math.floor((o.prefix_length + 31) / 32)
   s = s * 4
   pad = string.rep(_null, s-#b)
   return abstract_data.do_encode(self, o) .. b .. pad
end

-- prefix_ac_tlv

prefix_ac_tlv = ac_tlv:new_subclass{class='prefix_ac_tlv',
                                    tlv_type=AC_TLV_USP}

function prefix_ac_tlv:try_decode(cur)
   local o, err = ac_tlv.try_decode(self, cur)
   if not o then return o, err end
   local r, err = prefix_body:decode(o.body)
   if not r then return r, err end
   -- clear out body
   o.body = nil
   o.prefix = r.prefix .. '/' .. tostring(r.prefix_length)
   --o.prefix_length = r.prefix_length
   return o
end

function prefix_ac_tlv:do_encode(o)
   local l = mst.string_split(o.prefix, '/')
   if not o.prefix_length
   then
      -- figure prefix length frmo the prefix
      self:a(#l == 2, "invalid prefix", l)
      o.prefix_length = l[2]
   else
      self:a(#l <= 2, "invalid prefix", l)
   end
   o.prefix = l[1]
   local r = { prefix=o.prefix, prefix_length=o.prefix_length }
   local body = prefix_body:do_encode(r)
   o.body = body
   return ac_tlv.do_encode(self, o)
end

-- rhf_ac_tlv 

rhf_ac_tlv = ac_tlv:new{class='rhf_ac_tlv', tlv_type=AC_TLV_RHF}

function rhf_ac_tlv:try_decode(cur)
   local o, err = ac_tlv.try_decode(self, cur)
   if not o then return o, err end
   -- only constraint we have is that the length >= 32 (according 
   -- to draft-acee-ospf-ospfv3-autoconfig-03)
   if o.length < MINIMUM_AC_TLV_RHF_LENGTH
   then 
      return nil, 'too short RHF payload' 
   end
   return o
end

-- usp_ac_tlv

usp_ac_tlv = prefix_ac_tlv:new{class='usp_ac_tlv',
                               tlv_type=AC_TLV_USP}


-- asp_ac_tlv

asp_ac_tlv = prefix_ac_tlv:new{class='asp_ac_tlv',
                               format='type:u2 length:u2 iid:u4',
                               tlv_type=AC_TLV_ASP,
                               header_default={type=AC_TLV_ASP, 
                                               length=0, iid=0}}

-- tlv list decoding

local _tlv_decoders = {rhf_ac_tlv, usp_ac_tlv, asp_ac_tlv}

function decode_ac_tlvs(s)

   local cur = vstruct.cursor(s)
   mst.d('decode_ac_tlvs', #s)

   mst.d('decoders', #_tlv_decoders)
   local hls = mst.array_map(_tlv_decoders,
                             function (t) 
                                return t.header_length
                             end)
   mst.d('hls', hls)
   local minimum_size = mst.min(unpack(hls))
   mst.d('minimum_size', minimum_size)

   local t = {}
   while has_left(cur, minimum_size)
   do
      local found = false
      for i, v in ipairs(_tlv_decoders)
      do
         mst.d('looping decoder', i)

         local o, err = v:decode(cur)
         if o
         then
            table.insert(t, o)
            mst.d('decoded', o)
            found = true
            break
         end
      end
      mst.a(found, 'unable to decode', cur)
   end
   return t, cur.pos
end
