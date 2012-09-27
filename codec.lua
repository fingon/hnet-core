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
-- Last modified: Thu Sep 27 15:41:37 2012 mstenber
-- Edit time:     60 min
--

-- object-oriented codec stuff that handles encoding and decoding of
-- the network packets (or their parts)

-- key ideas

-- - employ vstruct for heavy lifting

-- - nestable (TLV inside LSA inside OSPF, for example)

-- - extensible

require 'mst'

abstract_data = mst.create_class{class='abstract_data'}

--- abstract_data baseclass

function abstract_data:init()
   if not self.header
   then
      self:a(self.format, "no header AND no format?!?")
      self.header=vstruct.compile('<' + self.format)
   end
   if not self.header_length
   then
      self.header_length = #self.header.pack(self.header_dummy)
   end
end

function abstract_data:decode(cur)
   pos = cur.pos
   o, err = self:try_decode(cur)
   if o
   then
      return o
   end
   -- decode failed => restore cursor to wherever it was
   cur.pos = pos
end

function abstract_data:try_decode(cur)
   if not has_left(cur, self.header_length) 
   then
      return nil, 'not enough left for header'
   end
   local o = self.header.decode(cur)
   return o
end
                                 
function has_left(cur, n)
   -- cur.pos is indexed by 'last read' position => 0 = start of file
   return (#cur.str - cur.pos) >= n
end


--- ac_tlv _instance_ of abstract_data (but we override class for debugging)

ac_tlv = abstract_data:new{class='ac_tlv',
                           format='type:u2 length:u2',
                           header_dummy={type=0, length=0}}

function ac_tlv:try_decode(cur)
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return o, err end
   -- then make sure there's also enough space left for the body
   if not has_left(cur, o.length) then nil, 'not enough for body' end

   o.body = cur:read(o.length)
   assert(#o.body == o.length)
   return o
end

function ac_tlv:encode(o)
   o.length = #o.body
   return self.header.pack(o) .. o.body
end

--- rhf_ac_tlv based on ac_tlv prototype instance (we still override class)

rhf_ac_tlv = ac_tlv:new{class='rhf_ac_tlv'}

function rhf_ac_tlv:try_decode(cur)
   local o, err = ac_tlv.try_decode(self, cur)
   if not o then return o, err end
   -- make sure we're correct TLV type
   if o.type ~= 1 then return nil, 'invalid TLV type' end
   -- only constraint we have is that the length > 32 (according 
   -- to draft-acee-ospf-ospfv3-autoconfig-03)
   if o.length <= 32 then return nil, 'too short RHF payload' end
   return o
end

function rhf_ac_tlv:valid()
   r, err = ac_tlv.valid(self)
   if not r
   then
      return r, err
   end
   return true
end

--- usp_ac_tlv_body
usp_ac_tlv_body = abstract_data:new{class='usp_ac_tlv_body',
                                    format='prefix_length:u1 reserved:3*u1'}

function usp_ac_tlv_body:try_decode(cur)
   local o, err = abstract_data.try_decode(self, cur)
   if not o then return o, err end
   s = math.floor((o.prefix_length + 31) / 32)
   s = s * 4
   if not has_left(cur, s) then return nil, 'not enough for prefix' end
   r = cur:read(s)
   -- xxx - what to do with the binary prefix we have?
end

--- usp_ac_tlv 

usp_ac_tlv = ac_tlv:new{class='usp_ac_tlv'}

