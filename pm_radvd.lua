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
-- Last modified: Thu Nov  8 07:39:13 2012 mstenber
-- Edit time:     3 min
--

require 'pm_handler'

module(..., package.seeall)

pm_radvd = pm_handler.pm_handler:new_subclass()

function pm_radvd:ready()
   return true
end

function pm_radvd:run()
   local fpath = self.pm.radvd_conf_filename
   local c = self:write_radvd_conf(fpath)
   self.shell('killall -9 radvd', true)
   self.shell('rm -f /var/run/radvd.pid', true)
   if c and c > 0
   then
      local radvd = self.pm.radvd or 'radvd'
      self.shell(radvd .. ' -C ' .. fpath)
   end
end

function pm_radvd:write_radvd_conf(fpath)
   local c = 0
   self:d('entered write_radvd_conf')
   -- write configuration on per-interface basis.. 
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
      t:insert('  AdvDefaultLifetime 600;')
      for i, addr in ipairs(self.pm.ospf_dns or {})
      do
         -- space-separated addresses are ok here (unlike DHCP)
         t:insert('  RDNSS ' .. addr .. ' {};')
      end
      for i, suffix in ipairs(self.pm.ospf_dns_search or {})
      do
         local s = mst.string_strip(suffix)
         if #s > 0
         then
            t:insert('  DNSSL ' .. suffix .. ' {};')
         end
      end
      for i, lap in ipairs(self.pm.ospf_lap)
      do
         if lap.ifname == ifname
         then
            c = c + 1
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
   for i, v in ipairs(self.pm.ospf_lap)
   do
      rec(v.ifname)
   end
   f:write(t:join('\n'))
   f:write('\n')
   -- close the file
   io.close(f)
   return c
end

