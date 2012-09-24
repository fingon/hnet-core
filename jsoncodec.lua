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
-- Last modified: Mon Sep 24 11:31:31 2012 mstenber
-- Edit time:     37 min
--

-- json codec that can be plugged on top of scb abstracted sockets, to
-- get API to which you toss in dict's, and get dict's out
-- (or well, any structure that dkjson supports for encoding..)

require 'mst'
local struct = require 'struct'
local json = require "dkjson"

-- struct.size missing from some historic version in luarocks
local _is = #struct.pack("i", 0)

module(..., package.seeall)

jsoncodec = mst.create_class{class='jsoncodec'}

function jsoncodec:init()
   -- read queue
   self.rq = {}
   self.rql = 0

   -- 's' should have 'callback' which provides read data. let's steal it.
   -- similarly, add 'close_callback' so we can clean up cleanly
   self.s.callback = function (s)
      self:handle_data(s)
   end
   self.s.close_callback = function ()
      if self.close_callback
      then
         self.close_callback()
      end
      self:done()
   end
end

function jsoncodec:write(o)
   -- encode the blob in a string
   local s = json.encode(o)

   -- write encoded json representation to the underlying socket
   local x = struct.pack('ic0', string.len(s), s)
   self.s:write(x)
   self:d('wrote', #x)
end

function jsoncodec:rq_join()
   -- combine all strings
   self.rq = {table.concat(self.rq)}
   self:a(#self.rq == 1)
end

function jsoncodec:handle_data(x)
   self:d('handle_data')

   -- by default, just push it off to the rq
   table.insert(self.rq, x)
   self.rql = self.rql + #x
   local ri = 1

   while true
   do
      local need1 = ri + _is - 1
      -- special case handling 1: rql < _is => return (nothing to be done)
      if self.rql < need1
      then
         self:d('too short read queue', self.rql, need1)
         break
      end

      if #self.rq[1] < need1
      then
         self:d('not enough in first packet - joining')
         self:rq_join()
      end

      self:a(#self.rq[1] >= need1)

      cnt = struct.unpack('i', self.rq[1], ri)

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
      s = struct.unpack('ic0', self.rq[1], ri)
      o = json.decode(s)

      self:a(self.callback, 'no callback?!?')
      self:d('providing callback to client')
      self.callback(o)

      -- update the index and re-iterate
      ri = ri + need2
   end

   -- chop the first string appropriately
   if ri > 1
   then
      self:d('consuming some bytes', ri)

      self.rq[1] = string.sub(self.rq[1], ri)

      -- and decrement the rql
      self.rql = self.rql - (ri - 1)
   end
end

function jsoncodec:done()
   -- we're done; just propagate the info
      if self.done_callback
      then
         self.done_callback()
      end
   self.s:done()
end

function wrap_socket(d)
   mst.check_parameters("jsoncodec:wrap_socket", d, {"s"}, 3)
   local o = jsoncodec:new(d)
   return o
end
