#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_ospf.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Jan  2 11:20:29 2013 mstenber
-- Last modified: Thu Jan 10 16:12:51 2013 mstenber
-- Edit time:     16 min
--

-- This is mdns proxy implementation which uses OSPF for state
-- synchronization. In practise, the 'skv' field of mdns_ospf is used
-- for bidirectional passing of data to the OSPF.

-- outside => mdns
--    ospf-lap ( to check if master, or not )
--    ospf-mdns = {} (?)

-- mdns => outside
--    mdns.<ifname> = ..

-- TODO

--  - deal with mdns + ospf-mdns skv stuff (rw)
--  ( perhaps treat them as interface that 'everyone' owns, and cache
--  = what we get from others, own = what we publish)

-- - active re-querying of the data we have propagated

require 'mdns_core'

module(..., package.seeall)

local _mdns = mdns_core.mdns

mdns = _mdns:new_subclass{class='mdns_ospf',
                          mandatory={'sendto', 'skv'}}

function mdns:init()
   _mdns.init(self)
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
end

function mdns:kv_changed(k, v)
   if k == elsa_pa.OSPF_LAP_KEY
   then
      self:d('queueing lap update')

      self.ospf_lap = v
      self.update_lap = true
      self.master_if_set = self:calculate_if_master_set()
   end
end

function mdns:uninit()
   self.skv:remove_change_observer(self.f)
end

function mdns:run()
   if self.update_lap
   then
      local fresh = {}
      self:d('running lap update')

      self.update_lap = nil
      self:d('syncing ifs')
      mst.sync_tables(self.ifname2if, self.master_if_set,
                      -- remove spurious
                      function (k, v)
                         if v.active
                         then
                            self:d(' removing ', k)
                            self:remove_own_from_if(k)
                            self:remove_own_to_if(k)
                            v.active = nil
                         end
                      end,
                      -- add missing
                      function (k, v)
                         self:d(' adding ', k)
                         local o = self:get_if(k)
                         table.insert(fresh, o)
                         o.active = true
                      end
                      -- comparison omitted -> we don't _care_
                     )
      if mst.table_count(fresh) > 0
      then
         local non_fresh = self.master_if_set:difference(fresh)
         if non_fresh:count() > 0
         then
            self:add_cache_set_to_own_set(non_fresh, fresh)
         end
      end
   end
   return _mdns.run(self)
end

function mdns:should_run()
   if self.update_lap then return true end
   return _mdns.should_run(self)
end

function mdns:remove_own_from_if(fromif)
   -- remove 'own' ns entries for all interfaces we're master to,
   -- that originate from the ifname 'ifname' cache
   local fromns = self.if2cache[fromif]
   if not fromns then return end
   
   -- (or well, not necessarily _remove_, but set their state
   -- s.t. they will be removed shortly)
   for i, toif in ipairs(self.master_if_set:keys())
   do
      local ns = self.if2own[toif]
      if ns
      then
         for i, rr in ipairs(fromns:values())
         do
            local nrr = ns:find_rr(rr)
            if nrr
            then
               nrr:expire()
            end
         end
      end
   end
end

function mdns:remove_own_to_if(ifname)
   local ns = self.if2own[ifname]
   if not ns then return end
   for i, rr in ipairs(ns:values())
   do
      -- XXX do more?
      ns:remove_rr(rr)
   end
end

function mdns:add_cache_set_to_own_set(fromset, toset)
   for i, src in ipairs(fromset)
   do
      for i, dst in ipairs(toset)
      do
         self:add_cache_if_to_own_if(src, dst)
      end
   end
end

function mdns:add_cache_if_to_own_if(fromif, toif)
   -- these are always cache => own mappings;
   -- we never do own=>own
   local src = self.if2cache[fromif]
   if not src then return end
   for i, rr in ipairs(src:values())
   do
      self:insert_if_own_rr(toif, rr)
   end
end

function mdns:propagate_rr(rr, ifname)
   -- if we're not 'master' for that if, ignore it
   if not self.master_if_set[ifname] then return end

   for toif, _ in pairs(self.master_if_set)
   do
      if toif ~= ifname
      then
         -- if we have received the entry _from_ that interface,
         -- we don't want to propagate it there
         local ns = self:get_if(toif).cache
         if not ns:find_rr(rr)
         then
            -- there isn't conflict - so we can just peacefully insert
            -- the rr to the own list
            self:insert_if_own_rr(toif, rr)
         end
      end
   end
end

function mdns:calculate_if_master_set()
   local t = mst.set:new{}
   for i, lap in ipairs(self.ospf_lap)
   do
      local dep = lap.depracate      
      local own = lap.owner and not lap.external
      if not dep and own
      then
         t:insert(lap.ifname)
      end
   end
   return t
end

