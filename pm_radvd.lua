#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_radvd.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 06:51:43 2012 mstenber
-- Last modified: Tue Nov 12 11:02:43 2013 mstenber
-- Edit time:     45 min
--

require 'pm_handler'

module(..., package.seeall)

DEFAULT_PREFERRED_LIFETIME=1800
DEFAULT_VALID_LIFETIME=3600

local _parent = pm_handler.pm_handler_with_pa_dns

pm_radvd = _parent:new_subclass{class='pm_radvd'}

function pm_radvd:run()
   local fpath = self.config.radvd_conf_filename
   local c = self:write_radvd_conf(fpath)

   -- no changes in status quo -> do nothing
   if not c then return end

   -- something DID change.. kill old radvd first
   self.shell('killall -9 radvd', true)
   self.shell('rm -f /var/run/radvd.pid', true)

   -- and then start new one if it's warranted
   if c and c > 0
   then
      local radvd = self.config.radvd or 'radvd'
      self.shell(radvd .. ' -C ' .. fpath)
   end
   return 1
end

function pm_radvd:write_radvd_conf(fpath)
   local c = 0
   self:d('entered write_radvd_conf')
   -- write configuration on per-interface basis.. 

   local seen = {}
   local t = mst.array:new{}
   local ext_set = self.usp:get_external_if_set()

   local function rec(ifname)
      -- We ignore interface if we try to dump it multiple times (just
      -- one entry is enough), or if it's external interface; running
      -- radvd on interface we also listen on results in really,
      -- really bad things.
      if seen[ifname] or ext_set[ifname]
      then
         return
      end
      seen[ifname] = true
      t:insert('interface ' .. ifname .. ' {')
      t:insert('  AdvSendAdvert on;')
      t:insert('  AdvManagedFlag off;')
      t:insert('  AdvOtherConfigFlag off;')
      -- 5 minutes is max # we want to stay as default router if gone :p
      t:insert('  AdvDefaultLifetime 600;')
      for i, addr in ipairs(self.ospf_dns or {})
      do
         -- space-separated addresses are ok here (unlike DHCP)
         t:insert('  RDNSS ' .. addr .. ' {};')
      end
      for i, suffix in ipairs(self.ospf_dns_search or {})
      do
         local s = mst.string_strip(suffix)
         if #s > 0
         then
            t:insert('  DNSSL ' .. suffix .. ' {};')
         end
      end
      local now = self:time()
      for i, lap in ipairs(self.lap)
      do
         if lap.ifname == ifname and not lap[elsa_pa.PREFIX_CLASS_KEY]
         then
            local p = ipv6s.ipv6_prefix:new{ascii=lap.prefix}
            if not p:is_ipv4() 
            then
               c = c + 1
               t:insert('  prefix ' .. lap.prefix .. ' {')
               t:insert('    AdvOnLink on;')
               t:insert('    AdvAutonomous on;')
               local dep = lap.depracate
               -- has to be nil or 1
               mst.a(not dep or dep == 1)
               local pref, vpref = self:abs_to_delta(now, lap[elsa_pa.PREFERRED_KEY], DEFAULT_PREFERRED_LIFETIME)
               local valid, vvalid = self:abs_to_delta(now, lap[elsa_pa.VALID_KEY], DEFAULT_VALID_LIFETIME)
               if vpref and vvalid
               then
                  t:insert('    DecrementLifetimes on;')
               end
               if dep 
               then
                  pref = 0
                  self:d(' adding (depracated)', lap.prefix)
               else
                  -- wonder what would be good values here..
                  self:d(' adding (alive?)', lap.prefix)
               end
               t:insert(string.format('    AdvPreferredLifetime %d;', pref))
               t:insert(string.format('    AdvValidLifetime %d;', valid))
               t:insert('  };')
            end
         end
      end
      t:insert('};')
   end
   for i, v in ipairs(self.lap)
   do
      rec(v.ifname)
   end
   return self:write_to_file(fpath, t, '# ') and c
end

