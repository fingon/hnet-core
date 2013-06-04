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
-- Last modified: Tue Jun  4 11:12:00 2013 mstenber
-- Edit time:     40 min
--

-- Auto-configured hybrid proxy code.  It interacts with skv to
-- auto-configure itself, but in general hp_core base is used as-is.

require 'hp_core'
require 'elsa_pa'

module(..., package.seeall)

hybrid_ospf = hp_core.hybrid_proxy:new_subclass{name='hybrid_ospf',
                                                -- rid isn't
                                                -- mandatory, we get
                                                -- it from ospf
                                                mandatory={'domain', 
                                                           'mdns_resolve_callback',
                                                }
                                               }

function hybrid_ospf:uninit()
   self:detach_skv()
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
            ap:insert(o)

            if asp.rid ~= myrid
            then
               -- ip we look for in asa (these should be available for
               -- all but we don't care about our own ips)
               o.ip = self:get_rid_ip(asp.rid)
            end

            -- ifname we look for in lap
            if o.rid == myrid
            then
               for i, lap in ipairs(lap)
               do
                  if lap.iid == asp.iid
                  then
                     o.ifname = lap.ifname
                     break
                  end
               end
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
