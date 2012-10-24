#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_core.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Oct  4 19:40:42 2012 mstenber
-- Last modified: Thu Oct 25 00:30:18 2012 mstenber
-- Edit time:     195 min
--

-- main class living within PM, with interface to exterior world and
-- to skv

-- (this is testable; pm.lua isn't, as it provides just raw shell
-- access for i/o, and real live skv)

-- obviously, more lowlevel access library (rather than shell) would
-- be an option at some point too; for the time being, just having one
-- command 'run and return results as string' is kind of elegant, and
-- simple. hopefully it won't become bottleneck.

require 'mst'
require 'skv'
require 'elsa_pa'
require 'linux_if'
require 'os'

module(..., package.seeall)

-- rule table related constants
MAIN_TABLE='main'
-- we use the (128-length of prefix as preference on top of the base => 128)
RULE_PREF_MIN=1000
RULE_PREF_MAX=RULE_PREF_MIN + 128 


pm = mst.create_class{class='pm', mandatory={'skv', 'shell', 
                                             'radvd_conf_filename'}}

function pm:init()
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
   self.if_table = linux_if.if_table:new{shell=self.shell} 
   self.rule_table = linux_if.rule_table:new{shell=self.shell}
   self.applied_usp = {}
end

function pm:uninit()
   self.skv:remove_change_observer(self.f)
end

function pm:kv_changed(k, v)
   self.skv:add_change_observer(self.f_iflist, elsa_pa.OSPF_IFLIST_KEY)
   self.skv:add_change_observer(self.f_usp, elsa_pa.OSPF_USP_KEY)
   if k == elsa_pa.OSPF_USP_KEY
   then
      self.ospf_usp = v
      self:check_ospf_vs_real()
      self:check_rules()
   elseif k == elsa_pa.OSPF_LAP_KEY
   then
      self.ospf_lap = v
      self:check_ospf_vs_real()
   elseif k == elsa_pa.OSPF_DNS_KEY
   then
      self.ospf_dns = v
      self:check_ospf_vs_real(1)
   else
      -- if it looks like pd change, we may be also interested
      --if string.find(k, '^' .. elsa_pa.PD_KEY) then self:check_rules() end
   end
end

function pm:invalidate_rules()
   self:d('invalidating rules')
   self:a(self.rule_table)
   self:a(self.rule_table.foreach)
   self.rule_table:foreach(function (rule) rule.valid = nil end)
end

function pm:get_rules()
   return self.rule_table:filter(function (rule)
                                    self:a(type(rule.pref) == 'number')
                                    return rule.pref >= RULE_PREF_MIN and rule.pref <= RULE_PREF_MAX
                                 end)
end

function pm:delete_invalid_rules()
   local my_rules = self:get_rules()
   self:d('considering rules', #my_rules)
   for i, rule in ipairs(my_rules)
   do
      if not rule.valid
      then
         self:d('not valid', rule)
         rule:del(self.shell)
         -- remove it from rule table too (happy assumption about no failures)
         self.rule_table:remove(rule)
      else
         self:d('keeping valid rule', rule)
      end
   end
end

function pm:check_rules()
   if not self.ospf_usp
   then
      return
   end

   -- we have the internal rule_table object. we compare that against
   -- the state we have in skv for OSPF (pd changes should come via
   -- OSPF process, hopefully, to keep the dataflow consistent)

   -- refresh the state
   self.rule_table:parse()

   -- mark all rules non-valid 
   self:invalidate_rules()

   -- different cases for each USP prefix
   local validc = 0
   local pending1 = mst.array:new()

   for _, usp in ipairs(self.ospf_usp)
   do
      local sel = 'from ' .. usp.prefix
      local i1, i2, s = string.find(usp.prefix, '/(%d+)$')
      self:a('invalid prefix', usp.prefix)
      local bits = mst.strtol(s)
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
            if self.applied_usp[usp.prefix] == uspi
            then
               -- in rule table, not changed => nop
               o.valid = true
            else
               -- in rule table, changed => del + add
               -- prefix, nh, ifname, .. if any of those changes, it's bad news
               -- and we better remove + add back
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
   for _, usp in ipairs(validc > 0 and self.ospf_usp or {})
   do
      -- to rules just point at main table => no content to care about
      local sel = 'from all to ' .. usp.prefix
      local pref = RULE_PREF_MIN
      local template = {sel=sel, pref=pref, table=MAIN_TABLE}
      local o = self.rule_table:find(template)
      if o
      then
         o.valid = true
      else
         pending2:insert(template)
      end
   end

   -- in rule table, not in OSPF => del
   self:delete_invalid_rules()


   for i, v in ipairs(pending1)
   do
      local usp, template = unpack(v)

      -- store that it has been added
      local uspi = mst.repr(usp)
      self.applied_usp[usp.prefix] = uspi

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
end

function pm:get_real_lap()
   local r = mst.array:new{}

   local m = self.if_table:read_ip_ipv6()

   for _, ifo in ipairs(m:values())
   do
      for _, addr in ipairs(ifo.ipv6 or {})
      do
         local bits = ipv6s.prefix_bits(addr)
         if bits == 64
         then
            -- non-64 bit prefixes can't be eui64 either
            local prefix = ipv6s.eui64_to_prefix(addr)
            mst.a(not r[prefix])
            -- consider if we should even care about this prefix
            local found = nil
            for _, v in ipairs(self.ospf_usp or {})
            do
               self:d('considering', v.prefix, prefix)
               if ipv6s.prefix_contains(v.prefix, prefix)
               then
                  found = v
                  break
               end
            end
            if not found
            then
               self:d('ignoring prefix', prefix)
            else
               local o = {ifname=ifo.name, prefix=prefix, addr=addr}
               self:d('found', o)
               r:insert(o)
            end
         end
      end
   end
   return r
end

function pm:repr_data()
   return mst.repr{ospf_lap=self.ospf_lap and #self.ospf_lap or 0}
end

function pm:check_ospf_vs_real(changes)
   changes = changes or 0
   if not self.ospf_lap or not self.ospf_usp
   then
      return
   end
   local lap = self.ospf_lap
   local rlap = self:get_real_lap()
   self:d('lap_changed - rlap/lap', #rlap, #lap)
   -- both are lists of map's, with prefix+ifname keys
   --
   -- convert them to single table
   -- (prefixes should be unique, interfaces not necessarily)
   function laplist_to_map(l)
      local t = mst.map:new{}
      for i, v in ipairs(l)
      do
         self:a(not t[v.prefix])
         t[v.prefix] = v
      end
      return t
   end
   local ospf_lap = laplist_to_map(lap)
   local real_lap = laplist_to_map(rlap)
   local ospf_keys = ospf_lap:keys():to_set()
   local real_keys = real_lap:keys():to_set()

   local valid_end='::/64'

   -- 3 cases to consider
   -- only in ospf_lap
   for prefix, _ in pairs(ospf_keys:difference(real_keys))
   do
      mst.a(string.sub(prefix, -#valid_end) == valid_end, 
            'invalid prefix', prefix)
      self:handle_ospf_prefix(prefix, ospf_lap[prefix])
      changes = changes + 1
   end
   
   -- only in real_lap
   for prefix, _ in pairs(real_keys:difference(ospf_keys))
   do
      mst.a(string.sub(prefix, -#valid_end) == valid_end, 
            'invalid prefix', prefix)
      self:handle_real_prefix(prefix, real_lap[prefix])
      changes = changes + 1
   end
   
   -- in both
   for prefix, _ in pairs(real_keys:intersection(ospf_keys))
   do
      mst.a(string.sub(prefix, -#valid_end) == valid_end, 
            'invalid prefix', prefix)
      local c = 
         self:handle_both_prefix(prefix, ospf_lap[prefix], real_lap[prefix])
      if c then changes = changes + 1 end
   end

   -- rewrite the radvd configuration
   if changes > 0
   then
      self:write_radvd_conf()
      os.execute('killall -9 radvd 2>/dev/null')
      os.execute('sh -c "radvd -C ' .. self.radvd_conf_filename .. '" 2>/dev/null ')
   end
end

function pm:write_radvd_conf()
   -- write configuration on per-interface basis.. 
   local fpath = self.radvd_conf_filename
   local f, err = io.open(fpath, 'w')
   self:a(f, 'unable to open for writing', fpath, err)

   local seen = {}
   local t = mst.array:new{}

   -- this is O(n^2). oh well, number of local assignments should not
   -- be insane
   function rec(ifname)
      if seen[ifname]
      then
         return
      end
      seen[ifname] = true
      t:insert('interface ' .. ifname .. ' {')
      t:insert('  AdvSendAdvert on;')
      t:insert('  AdvManagedFlag off;')
      t:insert('  AdvOtherConfigFlag off;')
      t:insert('  AdvDefaultLifetime 600;')
      for i, addr in ipairs(self.ospf_dns or {})
      do
         t:insert('  RDNSS ' .. addr .. ' {};')
      end
      for i, lap in ipairs(self.ospf_lap)
      do
         if lap.ifname == ifname
         then
            t:insert('  prefix ' .. lap.prefix .. ' {')
            t:insert('    AdvOnLink on;')
            t:insert('    AdvAutonomous on;')
            local dep = lap.depracate
            self:a(dep) -- has to be 0 or 1, not nil
            mst.a(dep == 0 or dep == 1)
            if dep == 1
            then
               t:insert('    AdvValidLifetime 7200;')
               t:insert('    AdvPreferredLifetime 0;')
            else
               -- how much we want to advertise? let's stick to defaults for now
               --t:insert('    AdvValidLifetime 86400;')
               --t:insert('    AdvPreferredLifetime 14400;')
            end
            t:insert('  };')
         end
      end
      t:insert('};')
   end
   for i, v in ipairs(self.ospf_lap)
   do
      rec(v.ifname)
   end
   f:write(t:join('\n'))
   f:write('\n')
   -- close the file
   io.close(f)
end

function pm:handle_ospf_prefix(prefix, po)
   local hwaddr = self.if_table:get_if(po.ifname):get_hwaddr()
   local addr = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
   self:d('handle_ospf_prefix', po)
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr add %s dev %s', addr, po.ifname))
end


function pm:handle_real_prefix(prefix, po)
   -- prefix is only on real interface, but not in OSPF
   -- that means that we want to get rid of it.. let's do so
   self:d('handle_real_prefix', po)
   local addr = po.addr
   self:a(addr)
   local ifname = po.ifname
   self:a(ifname)
   return self.shell(string.format('ip -6 addr del %s dev %s', addr, ifname))
end

function pm:handle_both_prefix(prefix, po1, po2)
   self:d('handle_both_prefix', po1, po2)
   -- if same prefix is active both in OSPF worldview, and in reality,
   -- we're happy!
   if po1.ifname == po2.ifname
   then
      return
   end
   -- we pretend it's only on real interface (=remove), and then
   -- pretend it's only on OSPF interface (=add)
   self:handle_real_prefix(prefix, po2)
   self:handle_ospf_prefix(prefix, po1)
   return true
end

