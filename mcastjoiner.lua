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
-- Last modified: Thu Feb 21 12:31:00 2013 mstenber
-- Edit time:     4 min
--

-- Simple abstraction to handle multicast join/leave doing socket

-- Assume that subclasses or someone provides try_multicast_op - it is
-- our stubbable interface; alternatively, mcast6 (=group to join) and
-- mcasts (=socket to use) can be provided.

require 'mst'

module(..., package.seeall)

mcj = mst.create_class{class='mcj'}

function mcj:init()
   -- joined if's
   self.joined_if_set = mst.set:new{}
end

function mcj:set_if_joined_set(shouldjoin)
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

