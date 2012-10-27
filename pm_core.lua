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
-- Last modified: Sat Oct 27 14:24:40 2012 mstenber
-- Edit time:     300 min
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

local ipv4_end='/24' -- as it's really v4 looking string


pm = mst.create_class{class='pm', mandatory={'skv', 'shell', 
                                             'radvd_conf_filename',
                                             'dhcpd_conf_filename',
                                            }}

function pm:init()
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
   self.if_table = linux_if.if_table:new{shell=self.shell} 
   self.rule_table = linux_if.rule_table:new{shell=self.shell}
   self.applied_usp = {}

   -- all  usable prefixes we have been given _some day_; 
   -- this is the domain of prefixes that we control, and therefore
   -- also remove addresses as neccessary if they spuriously show up
   -- (= usp removed, but lap still around)
   self.all_ipv6_binary_prefixes = mst.set:new{}
end

function pm:uninit()
   self.skv:remove_change_observer(self.f)
end

function pm:kv_changed(k, v)
   self:d('kv_changed', k, v)
   self.skv:add_change_observer(self.f_iflist, elsa_pa.OSPF_IFLIST_KEY)
   self.skv:add_change_observer(self.f_usp, elsa_pa.OSPF_USP_KEY)
   if k == elsa_pa.OSPF_USP_KEY
   then
      self.ospf_usp = v or {}
      
      -- reset cache
      self.ipv6_ospf_usp = nil

      -- update the all_ipv6_usp
      for i, v in ipairs(self:get_ipv6_usp())
      do
         local bp = ipv6s.new_prefix_from_ascii(v.prefix):get_binary()
         self.all_ipv6_binary_prefixes:insert(bp)
      end

      self.pending_routecheck = true
      self.pending_rulecheck = true
   elseif k == elsa_pa.OSPF_LAP_KEY
   then
      self.ospf_lap = v or {}
      self.pending_routecheck = true
      self.pending_addrcheck = true
      -- depracation can cause addresses to become non-relevant
      -- => rewrite radvd.conf too (and dhcpd.conf - it may have
      -- been using address range which is now depracated)
      self.pending_rewrite_radvd = true
      self.pending_rewrite_dhcpd = true
   elseif k == elsa_pa.OSPF_DNS_KEY
   then
      self.ospf_dns = v or {}
      self.pending_rewrite_radvd = true
      self.pending_rewrite_dhcpd = true
   elseif k == elsa_pa.OSPF_DNS_SEARCH_KEY
   then
      self.ospf_dns_search = v or {}
      self.pending_rewrite_radvd = true
      self.pending_rewrite_dhcpd = true
   else
      -- if it looks like pd change, we may be also interested
      --if string.find(k, '^' .. elsa_pa.PD_KEY) then self:check_rules() end
   end
   self:schedule_run()
end

function pm:schedule_run()
   -- nop - someone else should e.g. use event loop here with
   -- 0-callback (to prevent duplicate actions on multiple skv changes
   -- in short period of time)
end

function pm:run()
   local actions = 0
   if self.pending_routecheck
   then
      self:check_ospf_vs_real()
      self.pending_routecheck = nil
      actions = actions + 1
   end
   if self.pending_rulecheck
   then
      self:check_rules()
      self.pending_rulecheck = nil
      actions = actions + 1
   end
   if self.pending_addrcheck
   then
      self:check_addresses()
      self.pending_addrcheck = nil
      actions = actions + 1
   end
   if self.pending_rewrite_radvd
   then
      self:write_radvd_conf()
      os.execute('killall -9 radvd 2>/dev/null')
      os.execute('sh -c "radvd -C ' .. self.radvd_conf_filename .. '" 2>/dev/null ')
      self.pending_rewrite_radvd = nil
      actions = actions + 1
   end
   if self.pending_rewrite_dhcpd
   then
      local owned = self:write_dhcpd_conf()
      os.execute('killall -9 dhcpd 2>/dev/null')
      if owned > 0
      then
         os.execute('sh -c "dhcpd -6 -cf ' .. self.dhcpd_conf_filename .. '" 2>/dev/null ')
      end
      self.pending_rewrite_dhcpd = nil
   end
   self:d('run result', actions)
   return actions > 0 and actions
end

function pm:check_addresses()
   -- look at all interfaces we _have_
   -- and the associated lap's - does the address match?
   if not self.ospf_lap
   then
      return
   end

   local m = self.if_table:read_ip_ipv4()
   local if2a = {}
   for i, lap in ipairs(self.ospf_lap)
   do
      if lap.address
      then
         if2a[lap.ifname] = lap.address
      end
   end


   for ifname, ifo in pairs(m)
   do
      local found = if2a[ifname]
      if ifo.ipv4 ~= found
      then
         if found
         then
            -- set address
            local base = mst.string_split(found, '/')[1]
            ifo:set_ipv4(base, '255.255.255.0')
         else
            -- we don't remove addresses, as that could be
            -- counterproductive in so many ways
         end
      end
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

function pm:get_ipv6_usp()
   if not self.ipv6_ospf_usp
   then
      self.ipv6_ospf_usp = 
         mst.array_filter(self.ospf_usp, function (usp)
                             local p = ipv6s.new_prefix_from_ascii(usp.prefix)
                             return not p:is_ipv4()
                                         end)
   end
   return self.ipv6_ospf_usp
end

function pm:check_rules()
   self:d('entering check_rules')

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

   for _, usp in ipairs(self:get_ipv6_usp())
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
   for _, usp in ipairs(validc > 0 and self:get_ipv6_usp() or {})
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
         local prefix = ipv6s.new_prefix_from_ascii(addr)
         local bits = prefix:get_binary_bits()
         if bits == 64
         then
            -- non-64 bit prefixes can't be eui64 either
            -- consider if we should even care about this prefix
            local found = nil
            local bp = prefix:get_binary()
            prefix:clear_tailing_bits()
            for bp2, _ in pairs(self.all_ipv6_binary_prefixes)
            do
               --self:d('considering', v.prefix, prefix)
               if ipv6s.binary_prefix_contains(bp2, bp)
               then
                  found = true
                  break
               end
            end
            if not found
            then
               self:d('ignoring prefix', prefix)
            else
               local o = {ifname=ifo.name, 
                          prefix=prefix:get_ascii(), 
                          addr=addr}
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

function pm:check_ospf_vs_real()
   local valid_end='::/64'

   self:d('entering check_ospf_vs_real')

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
         local ov = t[v.prefix]

         if not mst.string_endswith(v.prefix, ipv4_end)
         then
            -- if we don't have old value, or old one is 
            -- depracated, we clearly prefer the new one

            -- XXX - add test cases for this
            if not ov or ov.depracate
            then
               t[v.prefix] = v
            end
         end
      end
      return t
   end
   local ospf_lap = laplist_to_map(lap)
   local real_lap = laplist_to_map(rlap)
   local ospf_keys = ospf_lap:keys():to_set()
   local real_keys = real_lap:keys():to_set()

   local changes = 0

   -- 3 cases to consider
   -- only in ospf_lap
   for prefix, _ in pairs(ospf_keys:difference(real_keys))
   do
      mst.a(mst.string_endswith(prefix, valid_end),
            'invalid prefix', prefix)
      self:handle_ospf_prefix(prefix, ospf_lap[prefix])
      changes = changes + 1
   end
   
   -- only in real_lap
   for prefix, _ in pairs(real_keys:difference(ospf_keys))
   do
      mst.a(mst.string_endswith(prefix, valid_end),
            'invalid prefix', prefix)
      self:handle_real_prefix(prefix, real_lap[prefix])
      changes = changes + 1
   end
   
   -- in both
   for prefix, _ in pairs(real_keys:intersection(ospf_keys))
   do
      mst.a(mst.string_endswith(prefix, valid_end),
            'invalid prefix', prefix)
      local c = 
         self:handle_both_prefix(prefix, ospf_lap[prefix], real_lap[prefix])
      if c then changes = changes + 1 end
   end

   -- rewrite the radvd configuration
   if changes > 0
   then
      self.pending_rewrite_radvd = true
   end
end

function pm:write_dhcpd_conf()
   local owned = 0
   self:d('entered write_dhcpd_conf')

   local fpath = self.dhcpd_conf_filename
   local f, err = io.open(fpath, 'w')
   self:a(f, 'unable to open for writing', fpath, err)

   local t = mst.array:new{}

   t:insert([[
# dhcpd6.conf
# automatically generated by pm_core.lua
]])
   
   local dns = self.ospf_dns or {}
   if #dns > 0
   then
      local s = table.concat(dns,",")
      t:insert('option dhcp6.name-servers ' .. s .. ';')
   end
   local search = self.ospf_dns_search or {}

   if #search>0
   then
      local rl = mst.array_map(search, mst.repr)
      local s = table.concat(rl, ",")
      t:insert('option dhcp6.domain-search ' .. s .. ';')
      
   end

   -- for each locally assigned prefix, if we're the owner (=publisher
   -- of asp), run DHCPv6, otherwise not..
   handled = mst.set:new{}
   for i, lap in ipairs(self.ospf_lap)
   do
      local dep = lap.depracate      
      local own = lap.owner
      -- this is used to prevent more than one subnet per interface
      -- (sigh, ISC DHCP limitation #N)
      local already_done = handled[lap.ifname]
      if not dep and own and not already_done
      then
         handled:insert(lap.ifname)
         local p = ipv6s.ipv6_prefix:new{ascii=lap.prefix}
         if not p:is_ipv4()
         then
            owned = owned + 1
            local b = p:get_binary()
            local stb = b .. string.rep(string.char(0), 7) .. string.char(42)
            local enb = b .. string.rep(string.char(0), 7) .. string.char(123)
            local st = ipv6s.binary_address_to_address(stb)
            local en = ipv6s.binary_address_to_address(enb)
            t:insert('subnet6 ' .. lap.prefix .. ' {')
            t:insert('  range6 ' .. st .. ' ' .. en .. ';')
            t:insert('}')
         end
      end
   end
   f:write(t:join('\n'))
   f:write('\n')

   -- close the file
   io.close(f)
   return owned
end

function pm:write_radvd_conf()
   self:d('entered write_radvd_conf')
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
      -- 5 minutes is max # we want to stay as default router if gone :p
      t:insert('  AdvDefaultLifetime 300;')
      for i, addr in ipairs(self.ospf_dns or {})
      do
         t:insert('  RDNSS ' .. addr .. ' {};')
      end
      for i, suffix in ipairs(self.ospf_dns_search or {})
      do
         t:insert('  DNSSL ' .. suffix .. ' {};')
      end
      for i, lap in ipairs(self.ospf_lap)
      do
         if lap.ifname == ifname
         then
            local p = ipv6s.ipv6_prefix:new{ascii=lap.prefix}
            if not p:is_ipv4()
            then
               t:insert('  prefix ' .. lap.prefix .. ' {')
               t:insert('    AdvOnLink on;')
               t:insert('    AdvAutonomous on;')
               local dep = lap.depracate
               -- has to be nil or 1
               mst.a(not dep or dep == 1)
               if dep 
               then
                  t:insert('    AdvValidLifetime 60;')
                  t:insert('    AdvPreferredLifetime 0;')
                  self:d(' adding (depracated)', lap.prefix)
               else
                  -- wonder what would be good values here..
                  t:insert('    AdvValidLifetime 3600;')
                  t:insert('    AdvPreferredLifetime 1800;')
                  self:d(' adding (alive?)', lap.prefix)
               end
               t:insert('  };')
            end
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

