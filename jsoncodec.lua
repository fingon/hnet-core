#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: jsoncodec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Sep 20 18:30:13 2012 mstenber
-- Last modified: Thu Sep 27 13:41:30 2012 mstenber
-- Edit time:     59 min
--

-- json codec that can be plugged on top of scb abstracted sockets, to
-- get API to which you toss in dict's, and get dict's out
-- (or well, any structure that dkjson supports for encoding..)

require 'mst'
local vstruct = require 'vstruct'
local json = require "dkjson"

HEADER_MAGIC=1234567

-- < = network endian
local _format = vstruct.compile('< magic:u4 size:u4')

-- magic + length of the next payload
local _hs = #_format.pack({magic=HEADER_MAGIC,size=0})

module(..., package.seeall)

jsoncodec = mst.create_class{class='jsoncodec'}

function jsoncodec:init()
   -- read queue
   self.rq = {}
   self.rql = 0

   self.read = 0
   self.written = 0

   -- 's' should have 'callback' which provides read data. let's steal it.
   -- similarly, add 'close_callback' so we can clean up cleanly
   self.s.callback = function (s)
      self:handle_data(s)
   end
   self.s.close_callback = function ()
      self:handle_close()
   end
end

function jsoncodec:uninit()
   -- we're done; just propagate the info
   self:call_callback_once('done_callback')
   self.s:done()
end

function jsoncodec:repr_data()
   return string.format('s:%s #rq:%d rql:%d',
                        mst.repr(self.s),
                        #self.rq,
                        self.rql)
end

function jsoncodec:write(o)
   self:d('write', o)

   -- encode the blob in a string
   local s = json.encode(o)

   -- write encoded json representation to the underlying socket
   local x = _format.pack{magic=HEADER_MAGIC, size=string.len(s)} .. s
   self.s:write(x)
   self.written = self.written + #x
   self:d('wrote', #x, self.written)
end

function jsoncodec:rq_join()
   -- combine all strings
   self.rq = {table.concat(self.rq)}
   self:a(#self.rq == 1)
end

function jsoncodec:handle_close()
   self:call_callback_once('close_callback')
   self:done()
end

function jsoncodec:handle_data(x)
   self:d('handle_data')

   -- by default, just push it off to the rq
   table.insert(self.rq, x)
   self.rql = self.rql + #x
   local ri = 1
   while true
   do
      local need1 = ri + _hs - 1
      -- special case handling 1: rql < _is => return (nothing to be done)
      if self.rql < need1
      then
         self:d('too short read queue', self.rql, ri, need1)
         break
      end

      if #self.rq[1] < need1
      then
         self:d('not enough in first packet - joining')
         self:rq_join()
      end

      self:a(#self.rq[1] >= need1)

      
      local cur = vstruct.cursor(ri == 1 and self.rq[1] or string.sub(self.rq[1], ri))
      local d = _format.unpack(cur)
      local magic = d.magic
      local cnt = d.size

      if magic ~= HEADER_MAGIC
      then
         self:d('invalid magic')
         self:handle_close()
         return
      end

      local need2 = need1 + cnt

      if self.rql < need2
      then
         self:d('too short read queue[2]', self.rql, need2)
         return
      end

      if #self.rq[1] < need2
      then
         self:d('not enough in first packet - joining[2]')
         self:rq_join()
      end
      
      self:a(#self.rq[1] >= need2)

      -- ok, we have a blob to decode
      local s = string.sub(self.rq[1], need1+1, need2)
      
      o = json.decode(s)

      self:a(self.callback, 'no callback?!?')
      self:d('providing callback to client')
      self.callback(o)

      -- update the index and re-iterate
      ri = need2 + 1
      self:d('handle_data iter', ri)
   end

   -- chop the first string appropriately
   if ri > 1
   then
      self:d('consuming some bytes', ri)

      self.read = self.read + (ri - 1)

      self.rq[1] = string.sub(self.rq[1], ri)

      -- and decrement the rql
      self.rql = self.rql - (ri - 1)
      mst.a(self.rql >= 0, "invalid rql", self)

   end
end

function wrap_socket(d)
   mst.check_parameters("jsoncodec:wrap_socket", d, {"s"}, 3)
   local o = jsoncodec:new(d)
   return o
end
