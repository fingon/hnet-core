#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dhcpv6codec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Feb 20 18:30:04 2013 mstenber
-- Last modified: Wed Feb 20 20:17:58 2013 mstenber
-- Edit time:     69 min
--

require 'codec'
require 'ipv6s'
require 'dhcpv6_const'

module(..., package.seeall)

local MT_RELAY_FORW = dhcpv6_const.MT_RELAY_FORW
local MT_RELAY_REPL = dhcpv6_const.MT_RELAY_REPL
local _ad = codec.abstract_data

-- per-option bidirectional mapping between 'data' <> dict (that will
-- have type also hard-coded, so we don't need to worry about 'type'
-- at this stage)

option_map = {
   [dhcpv6_const.O_ORO]={
      decode = function (data)
         if #data % 2 > 0 then return nil, 'non-even # of bytes in payload' end
         local t = {}
         mst.d('got data', #data)
         for i = 1, #data/2
         do
            local b1 = string.byte(data, 2 * i - 1, 2 * i - 1)
            local b2 = string.byte(data, 2 * i, 2 * i)
            table.insert(t, b1 * 256 + b2)
         end
         return t
      end,
      encode = function (o)
         local t = {}
         for i, v in ipairs(o)
         do
            table.insert(t, string.char(math.floor(v / 256)))
            table.insert(t, string.char(v % 256))
         end
         return table.concat(t)
      end,
   },
   [dhcpv6_const.O_DNS_RNS]={
      decode = function (data)
         if #data % 16 > 0 then return nil, 'non 16 divisible # of payload' end
         local t = {}
         for i = 1, #data/16
         do
            local st = (i - 1) * 16 + 1
            local en = st + 16
            local b = string.sub(data, st, en)
            mst.a(#b == 16)
            table.insert(t, ipv6s.binary_address_to_address(b))
         end
         return t
      end,
      encode = function (o)
         local t = {}
         for i, v in ipairs(o)
         do
            table.insert(t, ipv6s.address_to_binary_address(v))
         end
         return table.concat(t)
      end
   }
}

-- single DHCPv6 option _instance_
dhcpv6_option = _ad:new{class='dhcpv6_option',
                        format='option:u2 length:u2',
                        header_default={option=0, length=0},
                        copy_on_encode=true,}

function dhcpv6_option:try_decode(cur)
   local o, err = _ad.try_decode(self, cur)
   if not o then return o, err end
   -- ok, looks like we got the header. let's see if we can get the data too
   if not codec.cursor_has_left(cur, o.length)
   then
      return nil, 'out of space decoding body'
   end
   local data = cur:read(o.length)
   mst.a(#data == o.length)
   local t = tonumber(o.option)
   local h = option_map[t]
   if h
   then
      local no, err = h.decode(data)
      if not no then return nil, 'handler failed ' .. tostring(err) end
      no.option = o.option
      return no
   else
      self:d('no handler for type', t)
      o.length = nil
      data = mst.string_to_hex(data)
      o.data = data
      return o
   end
end

function dhcpv6_option:do_encode(o)
   local t = tonumber(o.option)
   local h = option_map[t]
   local data
   if h
   then
      data = h.encode(o)
      mst.a(data, 'unable to encode', o)
   else
      mst.a(o.data, 'no o.data?!?', o)
      data = mst.hex_to_string(o.data)
   end
   o.length = #data
   return _ad.do_encode(self, o) .. data
end

-- convenience subclass, which has header (child responsibility) +
-- a list of options.. as a Lua oddity, we treat the whole thing as a list
-- so the list has .headerfield=value parts, and [1]=first sub-option..
optlist = _ad:new_subclass{class='optlist'}

function optlist:try_decode(cur)
   local o, err = _ad.try_decode(self, cur)
   if not o then return o, err end
   while codec.cursor_has_left(cur, 4)
   do
      local o2, err2 = dhcpv6_option:decode(cur)
      if not o2 then return o2, err2 end
      table.insert(o, o2)
   end
   return o
end

function optlist:do_encode(o)
   local t = {}
   -- first header
   table.insert(t, _ad.do_encode(self, o))
   -- then all options
   for i, o2 in ipairs(o)
   do
      local s = dhcpv6_option:encode(o2)
      table.insert(t, s)
   end
   return table.concat(t)
end

-- class _instances_ for handling options with ugly content
data_ia_pd = optlist:new{class='data_ia_pd',
                         format='iaid:u4 t1:u4 t2:u4',
                         header_default={iaid=0, t1=0, t2=0}}

data_iaprefix = optlist:new{class='data_iaprefix',
                            format='preferred:u4 valid:u4 plength:u1 rawprefix:s16',
                            header_default={preferred=0, valid=0,
                                            plength=0, rawprefix=''},
                            copy_on_encode=true,
                           }

function data_iaprefix:try_decode(cur)
   local o, err = optlist.try_decode(self, cur)
   if not o then return nil, err end
   self:d('try_decode', o)
   -- replace rawprefix + plength with human-readable prefix
   self:a(o.rawprefix and o.plength)
   o.prefix = ipv6s.new_prefix_from_binary(o.rawprefix, o.plength):get_ascii()
   o.plength = nil
   o.rawprefix = nil
   return o
end

function data_iaprefix:do_encode(o)
   local p = ipv6s.new_prefix_from_ascii(o.prefix)
   o.rawprefix = p:get_binary()
   o.plength = p:get_binary_bits()
   return optlist.do_encode(self, o)
end


data_status_code = _ad:new{class='data_status_code',
                           format='code:u2 message:s',
                           header_default={code=0, message=''}}

data_uint16 = _ad:new{class='data_uint16',
                      format='value:u2',
                      header_default={value=0}}

data_uint8 = _ad:new{class='data_uint8',
                      format='value:u1',
                      header_default={value=0}}

-- class _instances_ for handling different types of DHCPv6 messages
dhcpv6_base_message = 
   optlist:new{class='dhcpv6_base_message',
               format='type:u1 xid:u3',
               header_default={type=0, xid=0}}

dhcpv6_relay_message = 
   optlist:new{class='dhcpv6_relay_message',
               format='type:u1 hopcount:u1 lladdr:s16 peeraddr:s16',
               header_default={type=0, hopcount=0,
                               lladdr='', peeraddr='',}
              }

-- wrapper class around dhcpv6_base_message and dhcpv6_relay_message
dhcpv6_message = codec.abstract_base:new{class='dhcpv6_message'}

function dhcpv6_message:try_decode(cur)
   if not codec.cursor_has_left(cur, 1)
   then
      return nil, 'empty cursor'
   end
   local opos = cur.pos
   local t = cur:read(1)
   cur:seek('set', opos)
   local mt = string.byte(t)
   if mt == MT_RELAY_FORW or mt == MT_RELAY_REPL
   then
      return dhcpv6_relay_message:decode(cur)
   else
      return dhcpv6_base_message:decode(cur)
   end
end

function dhcpv6_message:do_encode(o)
   if o.type == MT_RELAY_FORW or o.type == MT_RELAY_REPL
   then
      return dhcpv6_relay_message:encode(o)
   else
      return dhcpv6_base_message:encode(o)
   end
end

-- copy contents of option_to_clasS_map to option_map
option_to_class_map = {[dhcpv6_const.O_IA_PD]=data_ia_pd,
                       [dhcpv6_const.O_PREFERENCE]=data_uint8,
                       [dhcpv6_const.O_ELAPSED_TIME]=data_uint16,
                       [dhcpv6_const.O_IAPREFIX]=data_iaprefix,
                       [dhcpv6_const.O_STATUS_CODE]=data_status_code,
                       
}

for k, v in pairs(option_to_class_map)
do
   option_map[k]={
      decode = function (data)
         return v:decode(data)
      end,
      encode = function (o)
         return v:encode(o)
      end,
   }
end

