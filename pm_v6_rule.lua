#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_rule.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 07:12:11 2012 mstenber
-- Last modified: Thu Nov  8 07:57:41 2012 mstenber
-- Edit time:     2 min
--

require 'pm_handler'

module(..., package.seeall)

-- we use the (128-length of prefix as preference on top of the base => 128)
RULE_PREF_MIN=1000
RULE_PREF_MAX=RULE_PREF_MIN + 128 
MAIN_TABLE='main'

pm_v6_rule = pm_handler.pm_handler:new_subclass{class='pm_v6_rule'}

function pm_v6_rule:init()
   pm_handler.pm_handler.init(self)

   local rt = linux_if.rule_table:new{shell=self.shell}
   self.rule_table = rt
   local vs = mst.validity_sync:new{t=self.rule_table, single=true}
   self.vsrt = vs
   function vs:remove(rule)
      if rule.pref >= RULE_PREF_MIN and rule.pref <= RULE_PREF_MAX
      then
        rule:del(rt.shell)
      end
      rt:remove(rule)
   end
end

function pm_v6_rule:ready()
   return self.pm.ospf_usp
end

function pm_v6_rule:run()
   -- we have the internal rule_table object. we compare that against
   -- the state we have in skv for OSPF (pd changes should come via
   -- OSPF process, hopefully, to keep the dataflow consistent)

   -- refresh the state
   self.rule_table:parse()

   -- mark all rules non-valid 
   self.vsrt:clear_all_valid()

   -- different cases for each USP prefix
   local validc = 0
   local pending1 = mst.array:new()

   for _, usp in ipairs(self.pm:get_ipv6_usp())
   do
      local sel = 'from ' .. usp.prefix
      local i1, i2, s = string.find(usp.prefix, '/(%d+)$')
      self:a('invalid prefix', usp.prefix)
      local bits = tonumber(s)
      local pref = RULE_PREF_MIN + 128 - bits
      local template = {sel=sel, pref=pref}
      local o = self.rule_table:find(template)

      -- in this iteration, we don't care about USP that lack nh/ifname
      if usp.nh and usp.ifname
      then 
         validc = validc + 1 
         if not o
         then
            -- not in rule table => add
            -- (done in second pass)
         else
            local uspi = mst.repr(usp)
            if self.pm.applied_usp[usp.prefix] == uspi
            then
               -- in rule table, not changed => nop
               self.vsrt:set_valid(o)
            else
               -- in rule table, changed => del + add
               o = nil
            end
         end
         if not o
         then
            pending1:insert({usp, template})
         end
      end
   end
   
   -- if we don't have any valid source routes, we can also ignore 
   -- fixing of destination routes for source routed prefixes
   local pending2 = mst.array:new()
   for _, usp in ipairs(validc > 0 and self.pm:get_ipv6_usp() or {})
   do
      -- to rules just point at main table => no content to care about
      local sel = 'from all to ' .. usp.prefix
      local pref = RULE_PREF_MIN
      local template = {sel=sel, pref=pref, table=MAIN_TABLE}
      local o = self.rule_table:find(template)
      if o
      then
         self.vsrt:set_valid(o)
      else
         pending2:insert(template)
      end
   end

   -- in rule table, not in OSPF => del
   self.vsrt:remove_all_invalid()

   for i, v in ipairs(pending1)
   do
      local usp, template = unpack(v)

      -- store that it has been added
      local uspi = mst.repr(usp)
      self.pm.applied_usp[usp.prefix] = uspi

      -- figure table number
      local table = self.rule_table:get_free_table()
      template.table = table

      local r = self.rule_table:add_rule(template)

      -- and add it 
      r:add(self.shell)

      -- and flush the table
      self.shell('ip -6 route flush table ' .. table)
      
      -- and add the default route         
      nh = usp.nh
      dev = usp.ifname
      self.shell(string.format('ip -6 route add default via %s dev %s table %s',
                               nh, dev, table))
   end

   for i, template in ipairs(pending2)
   do
      local r = self.rule_table:add_rule(template)
      r:add(self.shell)
   end
   
   return 1
end

