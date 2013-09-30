#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v4_dhclient.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 07:17:26 2012 mstenber
-- Last modified: Mon Sep 30 17:18:00 2013 mstenber
-- Edit time:     6 min
--

require 'pm_handler'

module(..., package.seeall)

DHCLIENT_SCRIPT='/usr/share/hnet/dhclient_handler.sh'
DHCLIENT_PID_PREFIX='pm-pid-dhclient-'

pm_v4_dhclient = pm_handler.pm_handler_with_pa:new_subclass{class='pm_v4_dhclient'}

function pm_v4_dhclient:skv_changed(k, v)
   if k == elsa_pa.OSPF_RID_KEY
   then
      self.rid = v
      self:queue()
   end
end


function pm_v4_dhclient:run()
   -- oddly enough, we actually trust the OS (to a point); therefore,
   -- we keep only track of the dhclients we _think_ we have started,
   -- and just start-kill those as appropriate.
   local running_ifnames = mst.set:new{}
   for i, v in ipairs(mst.string_split(self.shell('ls -1 ' .. pm_core.PID_DIR), '\n'))
   do
      v = mst.string_strip(v)
      local rest = mst.string_startswith(v, DHCLIENT_PID_PREFIX)
      if rest
      then
         running_ifnames:insert(rest)
      end
   end


   -- get a list of interfaces with valid PD state
   local ipv6_usp = self.usp:get_ipv6()
   local rid = self.rid

   -- in cleanup, rid may be zeroed already
   --self:a(rid, 'no rid?!?')
   local ifnames = ipv6_usp:filter(function (usp) 
                                      return usp.rid == rid and usp.ifname
                                   end):map(function (usp) 
                                               return usp.ifname 
                                            end)
   local ifs = mst.array_to_table(ifnames)
   local c = mst.sync_tables(running_ifnames, ifs, 
                             -- remove
                             function (ifname)
                                local p = pm_core.PID_DIR .. '/' .. DHCLIENT_PID_PREFIX .. ifname
                                local s = string.format('%s stop %s %s', DHCLIENT_SCRIPT, ifname, p)
                                self.shell(s)
                             end,
                             -- add
                             function (ifname)
                                local p = pm_core.PID_DIR .. '/' .. DHCLIENT_PID_PREFIX .. ifname
                                local s = string.format('%s start %s %s', DHCLIENT_SCRIPT, ifname, p)
                                self.shell(s)
                             end
                             -- no equality - if it exists, it exists
                            )
   return c
end

