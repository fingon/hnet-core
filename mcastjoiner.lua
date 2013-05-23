#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mcastjoiner.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Feb 21 11:53:52 2013 mstenber
-- Last modified: Thu May 23 22:17:05 2013 mstenber
-- Edit time:     11 min
--

-- Simple abstraction to handle multicast join/leave doing socket

-- Assume that subclasses or someone provides try_multicast_op - it is
-- our stubbable interface; alternatively, mcast6 (=group to join) and
-- mcasts (=socket to use) can be provided.

require 'mst'
local _eventful = require 'mst_eventful'.eventful

module(..., package.seeall)

mcj = _eventful:new_subclass{class='mcj'}

function mcj:init()
   _eventful.init(self)

   -- joined if's
   self.joined_if_set = mst.set:new{}
end

function mcj:uninit()
   self:detach_skv()
end

function mcj:set_if_joined_set(shouldjoin)
   self:d('set_if_joined_set', shouldjoin)
   mst.sync_tables(self.joined_if_set, shouldjoin,
                   -- remove spurious
                   function (k, v)
                      self:leave_multicast(k)
                   end,
                   -- join new
                   function (k, v)
                      self:join_multicast(k)
                   end)
end

function mcj:join_multicast(ifname)
   self:a(ifname, 'ifname mandatory')
   local r, err = self:try_multicast_op(ifname, true)
   if r
   then
      self.joined_if_set:insert(ifname)
   else
      mst.d('join_multicast failed', ifname, err)
   end
end

function mcj:leave_multicast(ifname)
   self:a(ifname, 'ifname mandatory')
   local r, err = self:try_multicast_op(ifname, false)
   if r
   then
      self.joined_if_set:remove(ifname)
   else
      mst.d('leave_multicast failed', ifname, err)
   end
end

function mcj:try_multicast_op(ifname, is_join)
   -- no real multicast socket -> no harm, no foul?
   local s = self.mcasts
   if not s then return end

   local mcast6 = self.mcast6
   self:a(self.mcast6)
   local mct6 = {multiaddr=mcast6, interface=ifname}
   local opname = (is_join and 'ipv6-add-membership') or 'ipv6-drop-membership'
   mst.a(ifname and #ifname > 0)
   mst.d('try_multicast_op', ifname, is_join)
   return s:setoption(opname, mct6)
end


function mcj:attach_skv(skv, filter_lap)
   -- detach if we already were attached
   self:detach_skv()

   -- and attach now
   self.skv = skv
   self.f = function (_, pl)
      -- we can ignore key, we know it pl = list with
      -- relevant bit the 'address' (while it's just one IP in
      -- practise)

      -- convert to normal IP's
      local s = {}
      for i, lap in ipairs(pl)
      do
         if (not filter_lap or filter_lap(lap)) and lap.ifname
         then
            s[lap.ifname] = true
         end
      end
      self:set_if_joined_set(s)
   end
   self.skv:add_change_observer(self.f, elsa_pa.OSPF_LAP_KEY)
end

function mcj:detach_skv()
   if not self.skv
   then
      return
   end
   self.skv:remove_change_observer(self.f, elsa_pa.OSPF_LAP_KEY)
   self.skv = nil
   self.f = nil
end

