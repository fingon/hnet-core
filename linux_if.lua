#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: linux_if.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Mon Oct  8 13:11:02 2012 mstenber
-- Last modified: Thu Oct 18 12:17:18 2012 mstenber
-- Edit time:     80 min
--


-- wrapper library around 'ip' and 'ifconfig'
-- 
-- core ideas:
-- - cache things as long as we feel they're relevant
-- - use shell command given, and parse outputs
--   (could read /proc, or use netlink if we were fancy)

local mst = require 'mst'

module(..., package.seeall)

--- if_object

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
   local i1, i2, r = string.find(s, 'HWaddr ([0-9a-f:]+)%s*$')
   if not r
   then
      return nil, 'unable to parse ' .. s
   end
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

--- if_table

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

   local lines = mst.string_split(s, '\n')
   -- filter empty lines
   lines = lines:filter(function (line) return #mst.string_strip(line)>0 end)

   for i, line in ipairs(lines)
   do
      mst.string_find_one(line,
                          -- case 1: <num>: <ifname>: 
                          '^%d+: (%S+): ',
                          function (ifname)
                             ifo = self:get_if(ifname)
                             ifo.ipv6 = mst.array:new{}
                             ifo.ipv6_valid = true
                             ifo.valid = true
                          end,
                          -- case 2: <spaces> inet6 <addr>/64
                          '^%s+inet6 (%S+/64)%s',
                          function (addr)
                             ifo.ipv6:insert(addr)
                          end,
                          -- case 3: other inet6 stuff we ignore
                          '^%s+inet6',
                          nil
                         )
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


--- rule

rule = mst.create_class{class='rule', mandatory={'pref', 'sel', 'table'}}

function rule:del(sh)
   self:apply(sh, 'del')
end

function rule:add(sh)
   self:apply(sh, 'add')
end

function rule:apply(sh, op)
   sh(string.format('ip -6 rule %s %s table %s pref %d',
                    op, self.sel, self.table, self.pref))
end

--- rule_table
--- wrapper around the AF-specific ip rules
--- no real keys, but priority+conditions should be unique (I think)

rule_table = mst.array:new_subclass{class='rule_table', mandatory={'shell'},
                                    start_table=1000}

function rule_table:find(criteria)
   for _, o in ipairs(self)
   do
      if mst.table_contains(o, criteria) then return o end
   end
end

function rule_table:parse()
   -- start by invalidating current objects
   for i, v in ipairs(self)
   do
      v.valid = false
   end

   local s, err = self.shell("ip -6 rule")
   mst.a(s, 'unable to execute ip -6 rule', err)

   local lines = mst.string_split(s, '\n')
   -- filter empty lines
   lines = lines:filter(function (line) return #mst.string_strip(line)>0 end)
   self:d('parsing lines', #lines)

   for i, line in ipairs(lines)
   do
      line = mst.string_strip(line)

      function handle_line(pref, sel, table)
         pref = mst.strtol(pref)
         local o = {pref=pref, sel=sel, table=table}
         local r = self:find(o)
         if not r
         then
            r = self:add_rule(o)
         else
            self:d('already had?', r)
         end
         r.valid = true
      end

      --self:d('line', line)
      mst.string_find_one(line,
                          '^(%d+):%s+(from %S+)%s+lookup (%S+)$',
                          handle_line,
                          '^(%d+):%s+(from all to %S+)%s+lookup (%S+)$',
                          handle_line)
   end

   -- get rid of non-valid entries
   invalid = self:filter(function (o) return not o.valid end)
   for i, v in ipairs(invalid)
   do
      self:remove(v)
   end
end

function rule_table:add_rule(criteria)
   local r = rule:new(criteria)
   self:d('adding rule', r)
   self:insert(r)
   return r
end

function rule_table:get_free_table()
   local t = self.start_table
   while self:find{table=tostring(t)}
   do
      t = t + 1
   end
   return tostring(t)
end
