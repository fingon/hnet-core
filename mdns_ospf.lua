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
-- Last modified: Wed Jan 23 18:16:56 2013 mstenber
-- Edit time:     101 min
--

-- This is mdns proxy implementation which uses OSPF for state
-- synchronization. In practise, the 'skv' field of mdns_ospf is used
-- for bidirectional passing of data to the OSPF.

-- outside => mdns
--    ospf-lap ( to check if owner, or not )
--    ospf-mdns = {} 

-- mdns => outside
--    mdns = {}

-- ospf-mdns, and mdns contain entries with {name={'x','y','z'},
-- rtype=N, rdata_N='...'} format. Omitted things: 

-- - cache_flush bit (we assume we know which rtypes are; typically,
-- everything not PTR seems to be)

-- - ttl (we use mdns defaults, as stuff in OSPF is 'valid for now',
-- and once it disappears from OSPF, it should also disappear from
-- hosts)

-- - rdata_N is human readable rtype-specific version (mostly for
-- debugging purposes for now; it could be also raw rdata )

-- Most of the heavy lifting is done by the mdns_{core,if}; they
-- provide basic mdns abstraction, and all we do is just customize
-- those classes to our needs by subclassing. Namely, 

-- mdns_if is subclassed so that we're interested in refreshing cache
-- validity times if and only if we're owner for that interface
-- according to OSPF, and to get notifications whenever contents of
-- cache have changed (in terms of rr's having been added or removed)

-- mdns_core subclassing is to just to package the skv listening stuff
-- which does others => us propagation, as well as our caches => ospf
-- state transfer.


require 'mdns_core'
require 'mdns_if'

module(..., package.seeall)

-- locally owned (owner) interfaces' cache rr data
OWN_SKV_KEY='mdns'

-- other nodes' cache data skv key
OSPF_SKV_KEY='ospf-mdns'

local _mdns_if = mdns_if.mdns_if
local _mdns = mdns_core.mdns

ospf_if = _mdns_if:new_subclass{class='ospf_if'}

function ospf_if:init()
   -- call superclass init
   _mdns_if.init(self)

   local old_removed_callback = self.cache.removed_callback

   function self.cache.removed_callback(x, rr)
      -- set flag which indicates that the interface's cache is dirty
      self.parent.cache_dirty = true

      old_removed_callback(x, rr)
   end

   function self.cache.inserted_callback(x, rr)
      -- set flag which indicates that the interface's cache is dirty
      self.parent.cache_dirty = true
   end
end

-- by default, OSPF based interfaces are interested in EVERYTHING, 
-- as long as they're master
function ospf_if:interested_in_cached(rr)
   -- if not master, not interested
   if not self.parent.master_if_set[self.ifname]
   then
      return
   end
   return _mdns_if.interested_in_cached(self, rr)
end

mdns = _mdns:new_subclass{class='mdns_ospf',
                          ifclass=ospf_if,
                          mandatory={'sendto', 'skv'}}

function mdns:init()
   _mdns.init(self)
   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
   self.ospf_cache_ns = dnsdb.ns:new{}
end

function mdns:kv_changed(k, v)
   if k == elsa_pa.OSPF_LAP_KEY
   then
      self:d('queueing lap update')
      self.ospf_lap = v
      self.update_lap = true
   end
   if k == OSPF_SKV_KEY
   then
      self:d('ospf-cache updated', #v)
      self.ospf_skv = v
      self.update_ospf = true
   end
end

function mdns:uninit()
   self.skv:remove_change_observer(self.f)
end

function mdns:handle_ospf_cache()
   -- OSPF cache contents changed. Two cases that we care about, per rr.
   -- a)
   --  rr was added
   -- b)
   --  rr was removed
   --
   -- To make this check relatively efficient, we keep dnsdb.ns of
   -- our own just for storing the ospf cache state
   -- (self.ospf_cache_ns), and sync ospf_skv with that


   -- ospf cache contents
   local ns = self.ospf_cache_ns

   -- invalidate the ns contents
   ns:iterate_rrs(function (rr) rr.invalid = true end)

   local l = self.ospf_skv
   self:d('refreshing from ospf-cache', #l)

   -- first, handle existing ones (call propagate, whatever it does
   -- for them..)
   for i, rr in ipairs(l)
   do
      local orr = ns:find_rr(rr)
      if orr
      then
         orr.invalid = nil
      else
         rr = ns:insert_rr(rr)
         self:d('added cache rr', rr)
      end
      if self:if_rr_has_cache_conflicts(nil, rr)
      then
         self:stop_propagate_conflicting_if_rr(nil, rr)
         self:d('stopping propagating', rr)
      else
         self:propagate_if_rr(nil, rr)
         self:d('propagating', rr)

      end
   end
   
   -- then, look for invalid ones
   ns:iterate_rrs(function (rr)
                     if not rr.invalid then return end
                     self:d('setting ttl=0', rr)
                     -- wtf should we do with this anyway? update with
                     -- ttl=0, and then get rid of it?
                     rr.ttl = 0
                     self:propagate_if_rr(nil, rr)
                     ns:remove_rr(rr)
                  end)
end

function mdns:run()
   if self.update_lap
   then
      local fresh = {}
      self:d('running lap update')

      self.master_if_set = self:calculate_if_master_set()
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
                            -- has implications on cache too
                            self.cache_dirty = true
                            v.active = nil
                         end
                      end,
                      -- add missing
                      function (k, v)
                         self:d(' adding ', k)
                         local o = self:get_if(k)
                         table.insert(fresh, o)
                         -- has implications on cache too
                         self.cache_dirty = true
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
   if self.update_ospf
   then
      self.update_ospf = nil
      self:handle_ospf_cache()
   end
   if self.cache_dirty
   then
      -- publish all owned interfaces' caches to skv
      self.cache_dirty = false
      local t = {}
      for ifname, ifo in pairs(self.ifname2if)
      do
         -- we care only about owned interfaces - rest can be ignored safely
         if self.master_if_set[ifname]
         then
            ifo.cache:iterate_rrs(function (rr)
                                     local rt = rr.rtype
                                     local to = dns_rdata.rtype_map[rt]
                                     local f = to and to.field or 'rdata'
                                     local v = rr[f]
                                     self:a(v, 'no rdata?', to, rr)
                                     table.insert(t,
                                                  {name=rr.name,
                                                   rtype=rt,
                                                   rclass=dns_const.CLASS_IN,
                                                   [f]=v,
                                                  })
                                  end)
         end
      end
      self:d('cache dirty, publishing cache', #t)
      self.skv:set(OWN_SKV_KEY, t)
   end
   return _mdns.run(self)
end

function mdns:should_run()
   if self.update_lap or self.cache_dirty or self.update_ospf then return true end
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
         fromns:iterate_rrs(function (rr)
                               local nrr = ns:find_rr(rr)
                               if nrr
                               then
                                  nrr:expire()
                               end
                            end)
      end
   end
end

function mdns:remove_own_to_if(ifname)
   local ns = self.if2own[ifname]
   if not ns then return end
   ns:iterate_rrs(function (rr)
                     -- XXX do more?
                     ns:remove_rr(rr)
                  end)
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
   src:iterate_rrs(function (rr)
                      self:insert_if_own_rr(toif, rr)
                   end)
end

function mdns:calculate_if_master_set()
   local t = mst.set:new{}

   -- for rest, we look at the SKV-LAP for stuff that we own, and that
   -- isn't depracated or external
   for i, lap in ipairs(self.ospf_lap)
   do
      local dep = lap.depracate      
      local own = lap.owner 
      local ext = lap.external
      if own and not ext and not dep
      then
         t:insert(lap.ifname)
      end
   end
   return t
end

function mdns:propagate_rr_to_ifo(rr, ifo)
   -- if we have received the entry _from_ that interface,
   -- we don't want to propagate it there
   local ns = ifo.cache
   if not ns:find_rr(rr)
   then
      -- there isn't conflict - so we can just peacefully insert
      -- the rr to the own list
      ifo:insert_own_rr(rr)
   end
end

function mdns:propagate_if_rr(ifname, rr)
   -- if we're not 'master' for that if, ignore it
   if ifname and not self.master_if_set[ifname] then return end

   for toif, _ in pairs(self.master_if_set)
   do
      if toif ~= ifname
      then
         local ifo = self:get_if(toif)
         self:propagate_rr_to_ifo(rr, ifo)
      end
   end
end

