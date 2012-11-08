#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_v6_listen_ra.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 09:13:53 2012 mstenber
-- Last modified: Thu Nov  8 10:06:46 2012 mstenber
-- Edit time:     18 min
--

-- pm_v6_listen_ra module turns on and off listening to router
-- advertisements on particular interfaces. this should be tied to the
-- interfaces being 'upstream' from the homenet router.

-- assumption is that all interfaces are by default in kernel default
-- state (XXX - should this change?), and we just manipulate them
-- between that, and the 'client' state

require 'pm_handler'
require 'linux_if'

module(..., package.seeall)

pm_v6_listen_ra = pm_handler.pm_handler:new_subclass{class='pm_v6_listen_ra'}

SCRIPT='/usr/share/hnet/listen_ra_handler.sh'
BASE='/proc/sys/net/ipv6/conf'

function pm_v6_listen_ra:init()
   -- superclass
   pm_handler.pm_handler.init(self)
   
   self.clientif = mst.set:new{}
end

function pm_v6_listen_ra:disable_ra(ifname)
   self.clientif:remove(ifname)
   self.shell(SCRIPT .. ' stop ' .. ifname)
end

function pm_v6_listen_ra:enable_ra(ifname)
   self.clientif:insert(ifname)
   self.shell(SCRIPT .. ' start ' .. ifname)
end

function pm_v6_listen_ra:check_if(ifname)
   local b = BASE .. '/' .. ifname .. '/' .. 'accept_ra'
   local d = mst.read_filename_to_string(b)
   if d and mst.string_strip(d) ~= '2'
   then
      self:d('accept_ra changed?', b, d)
      self.clientif:remove(ifname)
   end
end

function pm_v6_listen_ra:run()
   -- look at actual files (NOTE: this should be somehow done only in
   -- real env, sigh)

   -- Linux is a jungle, something changes this at times :p
   for i, v in ipairs(self.clientif:keys())
   do
      self:check_if(v)
   end

   -- figure which ones we should listen to - get OSPF USP with
   -- ifname set
   local usps = self.pm:get_ipv6_usp()
   local ospfif = mst.set:new{}
   mst.array_foreach(usps, 
                     function (usp)
                        if usp.ifname and not usp.nh
                        then
                           ospfif:insert(usp.ifname)
                        end
                     end)
   mst.sync_tables(self.clientif, ospfif,
                   -- remove spurious
                   function (ifname)
                      self:disable_ra(ifname)
                   end,
                   -- add new
                   function (ifname)
                      self:enable_ra(ifname)
                   end)
end


