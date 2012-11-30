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
-- Last modified: Fri Nov 30 12:25:15 2012 mstenber
-- Edit time:     213 min
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

abstract_data = mst.create_class{class='abstract_data',
                                 copy_on_encode=false}

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

function abstract_data:decode(cur)
   mst.a(not self._cur, '_cur left?!?', self, self._cur)
   if type(cur) == 'string'
   then
      cur = vstruct.cursor(cur)
   end
   self._cur = cur
   local pos = cur.pos
   local o, err
   mst.pcall_and_finally(function ()
                            o, err = self:try_decode()
                         end,
                         function ()
                            self._cur = nil
                         end)
   if o
   then
      return o
   end
   -- decode failed => restore cursor to wherever it was
   cur.pos = pos
   return nil, err
end

function abstract_data:try_decode()
   --self:d('try_decode', cur)
   local cur = self._cur
   if not self:has_left(self.header_length) 
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
   --self:d('encode', o)

   self:a(self.header, 'header missing - using class method instead of instance?')

   -- work on shallow copy if required
   if self.copy_on_encode
   then
      o = mst.table_copy(o)
   end

   -- call do_encode to do real things
   return self:do_encode(o)
end

function abstract_data:has_left(n)
   local cur = self._cur

   -- cur.pos is indexed by 'last read' position => 0 = start of file
   mst.a(type(n) == 'number')
   mst.a(type(cur) == 'table')

   return (#cur.str - cur.pos) >= n
end


function cursor_has_left(cur, n)
   mst.a(type(n) == 'number')
   mst.a(type(cur) == 'table')

   return (#cur.str - cur.pos) >= n
end

