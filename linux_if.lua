#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: linux_if.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  8 13:11:02 2012 mstenber
-- Last modified: Tue Oct  9 15:11:22 2012 mstenber
-- Edit time:     25 min
--


-- wrapper library around 'ip' and 'ifconfig'
-- 
-- core ideas:
-- - cache things as long as we feel they're relevant
-- - use shell command given, and parse outputs
--   (could read /proc, or use netlink if we were fancy)

local mst = require 'mst'

module(..., package.seeall)

if_object = mst.create_class{class='if_object', mandatory={'name'}}

function if_object:get_hwaddr()
   local ifname = self.name
   if self.hwaddr
   then
      return self.hwaddr
   end
   local s = self.parent.shell(string.format('ifconfig %s | grep HWaddr', ifname))
   if not s
   then
      return nil, 'unable to get'
   end

   s = mst.string_strip(s)
   local l = mst.string_split(s)
   -- take the last one
   r = l:slice(-1)[1]
   self.hwaddr = r
   return r
end

function if_object:add_ipv6(addr)
   self.ipv6_valid = false
   return self.parent.shell(string.format('ip -6 addr add %s dev %s', addr, self.name))
end

function if_object:del_ipv6(addr)
   self.ipv6_valid = false
   return self.parent.shell(string.format('ip -6 addr del %s dev %s', addr, self.name))
end


if_table = mst.create_class{class='if_table', mandatory={'shell'}}

function if_table:init()
   self.map = mst.map:new{}
end

-- this is really get-or-set operation..
function if_table:get_if(k)
   local r = self.map[k]
   if not r
   then
      r = if_object:new{name=k, parent=self}
      self.map[k] = r
   end
   return r
end

function if_table:read_ip_ipv6()
   -- invalidate all interfaces first
   for i, v in ipairs(self.map:values())
   do
      v.valid = false
   end

   local s, err = self.shell("ip -6 addr | egrep '(^[0-9]| scope global)' | grep -v  temporary")
   mst.a(s, 'unable to execute ip -6 addr', err)
   local ifo = nil
   local r = mst.array:new{}

   local lines = mst.string_split(s, '\n')
   -- filter empty lines
   lines = lines:filter(function (line) return #mst.string_strip(line)>0 end)

   for i, line in ipairs(lines)
   do
      -- either it starts with #: ifname: 
      -- OR space + inet6 ip/64 scope global ...
      local st = string.sub(line, 1, 1)
      if st ~= ' '
      then
         local l = mst.string_split(line, ':')
         mst.a(#l == 3, 'parse error', line)
         ifo = self:get_if(mst.string_strip(l[2]))
         ifo.ipv6 = mst.array:new{}
         ifo.ipv6_valid = true
         ifo.valid = true
      else
         -- address
         mst.a(ifo, 'no interface object')
         line = mst.string_strip(line)
         local l = mst.string_split(line, ' ')
         mst.a(#l >= 4)
         mst.a(l[1] == 'inet6')
         addr = l[2]
         ifo.ipv6:insert(addr)
      end
   end

   -- remove non-valid interface objects
   for i, k in ipairs(self.map:keys())
   do
      local v = self.map[k]
      if not v.valid
      then
         self[k] = nil
      else
         -- no point carrying this info onward..
         v.valid = nil
      end
   end

   return self.map
end
