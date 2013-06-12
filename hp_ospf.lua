#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp_ospf.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May 23 14:11:50 2013 mstenber
-- Last modified: Wed Jun 12 12:31:12 2013 mstenber
-- Edit time:     55 min
--

-- Auto-configured hybrid proxy code.  It interacts with skv to
-- auto-configure itself, but in general hp_core base is used as-is.

require 'hp_core'
require 'elsa_pa'

module(..., package.seeall)

-- this filter function can be used in e.g. attach_skv of mcastjoiner;
-- it is also used directly here. regardless, all 3 elements of a
-- hybrid proxy (hp*, which provides dns, per_ip_server with N
-- dns_proxy instances, and mdns_client) should have _same_ idea of
-- valid laps to use. otherwise, not so happy things happen..
function valid_lap_filter(lap)
   -- we're interested about _any_ if! even if
   -- we're not owner, as we have to give answers
   -- for our own address. however, if we're
   -- deprecated, then not that good.. or external,
   -- perhaps
   local ext = lap.external
   local dep = lap.depracate
   return not ext and not dep
end

hybrid_ospf = hp_core.hybrid_proxy:new_subclass{name='hybrid_ospf',
                                                -- rid isn't
                                                -- mandatory, we get
                                                -- it from ospf
                                                mandatory={'domain', 
                                                           'mdns_resolve_callback',
                                                },
                                                lap_filter=valid_lap_filter,
                                               }

function hybrid_ospf:uninit()
   self:detach_skv()
end

function hybrid_ospf:recreate_tree()
   local root = hp_core.hybrid_proxy.recreate_tree()
   -- XXX - do we want to do something more?
   return root
end

function hybrid_ospf:attach_skv(skv)
   self:detach_skv()

   self.skv = skv
   -- The listening to appropriate IP addresses etc is handled in
   -- per_ip_server. So, what we care about is:

   -- - router id
   -- - usp (for usable prefix ranges)
   -- - asp (for assigned prefixes)
   -- - asa (for assigned addresses)
   self.f = function (k, v)
      self:d('skv notification', k)
      if k == elsa_pa.OSPF_RID_KEY
      then
         self.rid = v
         self.root = nil -- invalidate tree
         return
      end
      if k == elsa_pa.OSPF_IPV4_DNS_KEY
      then
         self.ospf_v4_dns = v or {}
         return
      end
      if k == elsa_pa.OSPF_DNS_KEY
      then
         self.ospf_dns = v or {}
      end
      if k == elsa_pa.OSPF_USP_KEY
      then
         self.usp = v
      end
      if k == elsa_pa.OSPF_ASA_KEY 
      then
         self.rid2ip = nil
      end
      if k == elsa_pa.OSPF_RNAME_KEY
      then
         -- invalidates tree (at the very least)
         self.root = nil
      end
      if k == elsa_pa.OSPF_ASP_KEY or 
         k == elsa_pa.OSPF_LAP_KEY or 
         k == elsa_pa.OSPF_ASA_KEY
      then
         -- ap = nil -> get_ap() will calculate it
         self.ap = nil
         -- invalidated tree => next time it's needed it is recalculated
         self.root = nil -- invalidate tree
      end
   end
   self.skv:add_change_observer(self.f, true)
end

function hybrid_ospf:iterate_usable_prefixes(f)
   if not self.usp
   then
      return
   end
   for i, v in ipairs(self.usp)
   do
      f(v.prefix)
   end
end

function hybrid_ospf:get_rid_ip(rid)
   if not self.rid2ip
   then
      local asa = self.skv:get(elsa_pa.OSPF_ASA_KEY)
      local h = {}
      self.rid2ip = h

      for i, o in ipairs(asa or {})
      do
         --self:d('handling', o)
         h[o.rid] = o.prefix
      end
      self:d('initialized get_rid_ip', h)
   end
   -- the asa ones have /32 or /128 at the end => skip that
   local ip = self.rid2ip[rid]
   if ip
   then
      return mst.string_split(ip, '/')[1]
   end
end

function hybrid_ospf:get_ap()
   if not self.ap
   then
      local ap = mst.array:new{}
      self.ap = ap
      local myrid = self.skv:get(elsa_pa.OSPF_RID_KEY)
      local asp = self.skv:get(elsa_pa.OSPF_ASP_KEY)
      local asa = self.skv:get(elsa_pa.OSPF_ASA_KEY)
      local lap = self.skv:get(elsa_pa.OSPF_LAP_KEY)
      if myrid and asp and asa and lap
      then
         -- without all of this info available, kinda little point..
         for i, asp in ipairs(asp)
         do
            -- 'ap' is supposed to contain rid, iid[, ip][, prefix],
            -- and [ifname]
            local o = {rid=asp.rid, iid=asp.iid, prefix=asp.prefix}

            if asp.rid ~= myrid
            then
               -- ip we look for in asa (these should be available for
               -- all but we don't care about our own ips)
               o.ip = self:get_rid_ip(asp.rid)
            end

            -- ifname we look for in lap
            local found = true
            if o.rid == myrid
            then
               found = nil
               for i, lap in ipairs(lap)
               do
                  if lap.iid == asp.iid and (not self.lap_filter or
                                             self.lap_filter(lap))
                  then
                     found = true
                     o.ifname = lap.ifname
                     break
                  end
               end
            end
            if found
            then
               ap:insert(o)
            end
         end
      end
   end
   self:a(self.ap, 'self.ap creation failed?!?')
   return self.ap
end

function hybrid_ospf:iterate_ap(f)
   -- 'ap' is supposed to contain rid, iid[, ip][, prefix], and [ifname]
   for i, v in ipairs(self:get_ap())
   do
      f(v)
   end
end

function hybrid_ospf:detach_skv()
   if not self.skv
   then
      return
   end
   self.skv:remove_change_observer(self.f, true)
   self.f = nil
   self.skv = nil
end

function hybrid_ospf:get_server()
   local l = self.ospf_dns 
   if l and #l > 0
   then
      return l[1]
   end
   local l = self.ospf_v4_dns 
   if l and #l > 0
   then
      return l[1]
   end
   return hp_core.hybrid_proxy.get_server(self)
end

function hybrid_ospf:rid2label(rid)
   -- by default, take it from OSPF_RNAME_KEY in skv
   local n = (self.skv:get(elsa_pa.OSPF_RNAME_KEY) or {})[rid]
   if n
   then
      return n
   end
   -- if no luck, fallback to parent
   return hp_core.hybrid_proxy.rid2label(self, rid)
end

