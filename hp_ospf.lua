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
-- Last modified: Wed Jun 12 14:48:35 2013 mstenber
-- Edit time:     85 min
--

-- Auto-configured hybrid proxy code.  It interacts with skv to
-- auto-configure itself, but in general hp_core base is used as-is.

require 'hp_core'
require 'elsa_pa'

module(..., package.seeall)

local _hp = hp_core.hybrid_proxy

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

hybrid_ospf = _hp:new_subclass{name='hybrid_ospf',
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
   self.local_zones = {}
   self.search_path = {dns_db.ll2name(self.domain)}
   local root = _hp.recreate_tree(self)
   self.skv:set(elsa_pa.HP_MDNS_ZONES_KEY, self.local_zones)
   self.skv:set(elsa_pa.HP_SEARCH_LIST_KEY, self.search_path)
   return root
end

function hybrid_ospf:create_local_forward_node(router, o)
   local n = _hp.create_local_forward_node(self, router, o)
   if not n then return end
   local ip = self:get_ip()
   if not ip then return end
   local o2 = {
      name=n:get_fqdn(),
      ip=ip,
      browse=1,
   }
   table.insert(self.local_zones, o2)
end

function hybrid_ospf:create_local_reverse_node(root, router, o)
   local n = _hp.create_local_reverse_node(self, root, router, o)
   if not n then return end
   local ip = self:get_ip()
   if not ip then return end
   -- don't browse reverse zones..
   local o2 = {
      name=n:get_fqdn(),
      ip=ip,
   }
   table.insert(self.local_zones, o2)
end

function hybrid_ospf:create_remote_zone(root, zone)
   local n = _hp.create_remote_zone(self, root, zone)
   self:d('create_remote_zone', zone, n)
   if not n then return end
   if zone.search
   then
      table.insert(self.search_path, n:get_fqdn())
   end
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
      elseif k == elsa_pa.OSPF_RNAME_KEY
      then
         self.rname = v
      elseif k == elsa_pa.OSPF_IPV4_DNS_KEY
      then
         -- no need for tree invalidation (handled in :get_server per-request)
         self.ospf_v4_dns = v or {}
         return
      elseif k == elsa_pa.OSPF_DNS_KEY
      then
         -- no need for tree invalidation (handled in :get_server per-request)
         self.ospf_dns = v or {}
         return
      elseif k == elsa_pa.OSPF_USP_KEY
      then
         self.usp = v
      elseif k == elsa_pa.OSPF_HP_DOMAIN_KEY
      then
         -- domain has changed (perhaps)
         self.domain = v
      elseif k == elsa_pa.OSPF_HP_ZONES_KEY
      then
         -- domain has changed (perhaps)
         self.zones = v
      elseif k == elsa_pa.OSPF_LAP_KEY 
      then
         self.lap = v
      else
         -- unknown key => no need to invalidate tree, hopefully ;-)
         return
      end
      self.root = nil -- invalidate tree
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

function hybrid_ospf:iterate_lap(f)
   if not self.lap
   then
      return
   end
   for i, lap in ipairs(mst.array_filter(self.lap, self.lap_filter))
   do
      f(lap)
   end
end

function hybrid_ospf:iterate_remote_zones(f)
   for i, zone in ipairs(self.zones or {})
   do
      f(zone)
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

function hybrid_ospf:get_ip()
   -- find _one_ ip that matches us
   for i, lap in ipairs(self.lap or {})
   do
      local ip = lap.address
      if ip
      then
         -- strip prefix, just in case
         ip = mst.string_split(ip, '/')[1]
         self:d('got ip', ip)
         return ip
      end
   end
   self:d('no ip available', self.lap)

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
   return _hp.get_server(self)
end

function hybrid_ospf:rid2label(rid)
   -- by default, take it from OSPF_RNAME_KEY in skv
   local m = self.rid2rname or {}
   local n = m[rid]
   if not n
   then
      -- fallback - if the types are somewhat non-equal
      -- (e.g. number <> integer <> string), normalize to strings and
      -- see if that works.

      local srid = tostring(rid)
      for k, v in pairs(m)
      do
         if tostring(k) == srid
         then
            n = v
         end
      end
   end
   self:d('rid2label', m, type(rid), rid, n)
   if n
   then
      return n
   end
   -- if no luck, fallback to parent
   return _hp.rid2label(self, rid)
end

