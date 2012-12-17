#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 15:07:49 2012 mstenber
-- Last modified: Mon Dec 17 16:19:34 2012 mstenber
-- Edit time:     28 min
--

-- This module contains the main mdns algorithm; it is not tied
-- directly to socket, event loop, or time functions. Instead,
-- bidirectional API is assumed to address those.

-- API from outside => mdns:
-- - run() - perform one iteration of whatever it does
-- - next_time() - when to run next time
-- - recvmsg(from, data)
-- - skv 
--    ospf-lap ( to check if master, or not )
--    ospf-mdns = {} (?)

-- API from mdns => outside:
-- - time() => current timestamp
-- - sendmsg(to, data)
--=> skv
--    mdns.if = .. ?

-- TODO: deal with mdns + ospf-mdns skv stuff (rw)

require 'mst'
require 'dnscodec'
require 'dnsdb'

module(..., package.seeall)

mdns = mst.create_class{class='mdns', mandatory={'time', 'sendmsg', 'skv'}}

function mdns:init()
   self.if2ns = {}
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
end

function pm:kv_changed(k, v)
   if k == elsa_pa.OSPF_LAP_KEY
   then
      self.ospf_lap = v
      self.update_lap = true
      self.master_if_set = self:calculate_if_master_set()
   end
end

function mdns:uninit()
   self.skv:remove_change_observer(self.f)
end

function mdns:run()
   local fresh = {}
   if self.update_lap
   then
      self.update_lap = nil
      self:d('syncing if2ns')
      mst.sync_tables(self.if2ns, self.master_if_set,
                      -- remove spurious
                      function (k, v)
                         self:d(' removing', k)

                         v:done()
                         self.if2ns[k] = nil
                      end,
                      -- add missing
                      function (k, v)
                         self:d(' adding', k)
                         local ns = dnsdb.ns:new{}
                         self.if2ns[ifname] = ns
                         table.insert(fresh, ns)
                      end,
                      -- comparison omitted -> we don't _care_
                     )
   end
   -- old ifs are ..?
   if fresh:count()
   then
      local non_fresh = self.master_if_set:difference(fresh)
      self:queue_announce_set_to_set(non_fresh, fresh)
   end
end

function mdns:queue_announce_set_to_set(fromset, toset)
   for i, src in ipairs(fromset)
   do
      for i, dst in ipairs(toset)
      do
         self:queue_announce_if_to_if(src, dst)
      end
   end
end

function mdns:queue_announce_if_to_if(fromif, toif)

end

function mdns:find_ns_for_ifname(ifname)
   return self.if2ns[ifname]
end

function mdns:lap_is_master(lap)
   local dep = lap.depracate      
   local own = lap.owner and not lap.external
   return not dep and own
end

function mdns:calculate_if_master_set()
   local t = mst.set:new{}
   for i, lap in ipairs(self.ospf_lap)
   do
      if self:lap_is_master(lap)
      then
         t:insert(lap.ifname)
      end
   end
   return t
end

function mdns:next_time()
   -- XXX
   return nil
end
