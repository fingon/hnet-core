#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: codec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Sep 27 13:46:47 2012 mstenber
-- Last modified: Fri Nov 30 13:33:59 2012 mstenber
-- Edit time:     221 min
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

--mst.enable_debug = true

-- abstract_base = base class, which just defines encode/decode API
-- but leaves do_encode/try_decode entirely up to subclasses
abstract_base = mst.create_class{class='abstract_base'}

function abstract_base:decode(cur, context)
   mst.a(not self._cur, '_cur left?!?', self, self._cur)
   if type(cur) == 'string'
   then
      cur = vstruct.cursor(cur)
   end
   local old_pos = cur.pos
   local o, err = self:try_decode(cur, context)
   if o
   then
      return o
   end
   -- decode failed => restore cursor to wherever it was
   cur.pos = old_pos
   return nil, err
end

function abstract_base:encode(o, context)
   --self:d('encode', o)

   -- work on shallow copy if required
   if self.copy_on_encode
   then
      o = mst.table_copy(o)
   end

   -- call do_encode to do real things (with the optional context parameter)
   return self:do_encode(o, context)
end

-- abstract_data = data with at least one thing from vstruct
abstract_data = abstract_base:new_subclass{class='abstract_data'}

--- abstract_data baseclass

function abstract_data:init()
   if not self.header
   then
      --mst.d('init header', self.format)
      self:a(self.format, "no header AND no format?!?")
      self.header=vstruct.compile('>' .. self.format)
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
   return mst.repr{format=self.format, 
                   header_length=self.header_length, 
                   header_default=self.header_default}
end

function abstract_data:try_decode(cur)
   if not cursor_has_left(cur, self.header_length) 
   then
      return nil, string.format('not enough left for header (%d<%d+%d)',
                                #cur.str, self.header_length, cur.pos)
   end
   local o = self.header.unpack(cur)
   return o
end
                                 
function abstract_data:do_encode(o)
   self:a(self.header, 'header missing - using class method instead of instance?')

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

function cursor_has_left(cur, n)
   mst.a(type(n) == 'number')
   mst.a(type(cur) == 'table', 'got wierd cursor', cur)
   return (#cur.str - cur.pos) >= n
end

