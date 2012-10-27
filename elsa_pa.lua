#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Oct  3 11:47:19 2012 mstenber
-- Last modified: Sat Oct 27 10:21:05 2012 mstenber
-- Edit time:     328 min
--

-- the main logic around with prefix assignment within e.g. BIRD works
-- 
-- elsa_pa is given skv instance, elsa instance, and should roll on
-- it's way.
--
-- the main difference is that this code assumes that there are LSAs;
-- pa code just deals with rid, asp, usp, if abstractions

-- #define LSA_T_AC        0xBFF0 /* Auto-Configuration LSA */
--  /* function code 8176(0x1FF0): experimental, U-bit=1, Area Scope */

-- XXX - document the API between elsa (wrapper), elsa_pa

-- => ospf_changed()
-- <= ???

require 'mst'
require 'codec'
require 'ssloop'

local pa = require 'pa'

module(..., package.seeall)

AC_TYPE=0xBFF0

PD_SKVPREFIX='pd-'
SIXRD_SKVPREFIX='6rd-'
SIXRD_DEV='6rd'

PREFIX_KEY='prefix.'
DNS_KEY='dns.'
DNS_SEARCH_KEY='dns-search.'
NH_KEY='nh.'

JSON_ASA_KEY='asa'
JSON_DNS_KEY='dns'
JSON_DNS_SEARCH_KEY='dns-search'

PD_IFLIST_KEY='pd-iflist'

OSPF_RID_KEY='ospf-rid'
OSPF_LAP_KEY='ospf-lap'
OSPF_USP_KEY='ospf-usp'
OSPF_DNS_KEY='ospf-dns'
OSPF_DNS_SEARCH_KEY='ospf-dns-search'
OSPF_IFLIST_KEY='ospf-iflist'

-- from the draft; time from boot to wait iff no other routers around
-- before starting new assignments
NEW_PREFIX_ASSIGNMENT=20

-- from the draft; time from boot to wait iff no other routers around
-- before generating ULA
NEW_ULA_PREFIX=20

-- =~ TERMINATE_PREFIX_ASSIGNMENT in the draft
LAP_DEPRACATE_TIMEOUT=240

-- not in the draft; the amount we keep deprecated prefixes around (to
-- e.g. advertise via radvd with zero prefix lifetime, and to reuse
-- first if need be)
LAP_EXPIRE_TIMEOUT=300

-- XXX - TERMINATE_ULA_PREFIX timeout is a 'SHOULD', but we ignore it
-- for simplicity's sake; getting rid of floating prefixes ASAP is
-- probably good thing (and the individual interface-assigned prefixes
-- will be depracated => will disappear soon anyway)

-- elsa specific lap subclass

elsa_lap = pa.lap:new_subclass{class='elsa_lap'}

function elsa_lap:start_depracate_timeout()
   local loop = ssloop.loop()
   self:d('start_depracate_timeout')
   self.timeout = loop:new_timeout_delta(LAP_DEPRACATE_TIMEOUT,
                                         function ()
                                            self.sm:Timeout()
                                         end)
   self.timeout:start()
end

function elsa_lap:stop_depracate_timeout()
   self:d('stop_depracate_timeout')

   mst.a(self.timeout, 'stop_depracate_timeout without timeout?!?')
   self.timeout:done()
   self.timeout = nil
end

function elsa_lap:start_expire_timeout()
   local loop = ssloop.loop()

   self:d('start_expire_timeout')
   self.timeout = loop:new_timeout_delta(LAP_EXPIRE_TIMEOUT,
                                         function ()
                                            self.sm:Timeout()
                                         end)
   self.timeout:start()
end

function elsa_lap:stop_expire_timeout()
   self:d('stop_expire_timeout')
   mst.a(self.timeout, 'stop_depracate_timeout without timeout?!?')
   self.timeout:done()
   self.timeout = nil
end


-- actual elsa_pa itself, which controls pa (and interfaces with
-- skv/elsa-wrapper
elsa_pa = mst.create_class{class='elsa_pa', mandatory={'skv', 'elsa'},
                          new_prefix_assignment=NEW_PREFIX_ASSIGNMENT,
                          new_ula_prefix=NEW_ULA_PREFIX}

function elsa_pa:init()
   self.first = true
   self.ridr_repr = ''
   self.skvp_repr = ''
   self.ospf_changes = 0
   self.pa = pa.pa:new{rid=self.rid, client=self, lap_class=elsa_lap,
                       new_prefix_assignment=self.new_prefix_assignment,
                       new_ula_prefix=self.new_ula_prefix}
   self.all_seen_if_names = mst.set:new{}
end

function elsa_pa:uninit()
   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state

   self.pa:done()
end

function elsa_pa:ospf_changed()
   self.ospf_changes = self.ospf_changes + 1
end

function elsa_pa:repr_data()
   return '-'
end

function elsa_pa:get_hwf(rid)
   rid = rid or self.rid
   local hwf = self.elsa:get_hwf(rid)
   mst.a(hwf)
   return hwf
end

function elsa_pa:get_padded_hwf(rid)
   local hwf = self:get_hwf(rid)
   mst.a(hwf, 'unable to get hwf')
   local d = codec.MINIMUM_AC_TLV_RHF_LENGTH
   if #hwf < d
   then
      hwf = hwf .. string.rep('1', d - #hwf)
   end
   mst.a(#hwf >= d)
   return hwf
end

function elsa_pa:check_conflict(bonus_lsa)
   local my_hwf = self:get_padded_hwf()
   local other_hwf = nil
   local lsas = 0
   local tlvs = 0
   function consider_lsa(lsa)
      lsas = lsas + 1
      if lsa.rid == self.rid
      then
         local found = nil
         for i, tlv in ipairs(codec.decode_ac_tlvs(lsa.body))
         do
            tlvs = tlvs + 1
            if tlv.type == codec.AC_TLV_RHF
            then
               found = tlv.body
            end
         end
         if found and found ~= my_hwf
         then
            other_hwf = found
         end
      end
   end

   if bonus_lsa then consider_lsa(bonus_lsa) end
   self:iterate_ac_lsa(consider_lsa)

   self:d('check_conflict considered', lsas, tlvs)
   if not other_hwf then return end
   self:d('found conflict', my_hwf, other_hwf)

   -- we have conflict; depending on what the hwf looks like,
   -- we either have to change our rid.. or not.

   -- if our hwf is greater, we don't need to change, but the other does
   if my_hwf > other_hwf
   then
      self:d('we have precedence, wait for other to renumber')

      return
   end

   self:d('trying to change local rid, as we lack precedence')


   -- uh oh, our hwf < other hwf -> have to change
   self.elsa:change_rid(self.rid)

   self.ospf_changes = 0
   self.had_conflict = true

   return true
end

function elsa_pa:run()
   self:d('run starting')

   -- let's check first that there is no conflict; that is,
   -- nobody else with different hw fingerprint, but same rid
   --
   -- if someone like that exists, either we (or they) have to change
   -- their router id..
   if self.ospf_changes == 0
   then
      if self.had_conflict
      then
         self:d('had conflict, no changes => still have conflict')
         return
      end
   else
      if self:check_conflict() then return end
   end
   
   self.skvp = mst.map:new()
   self:iterate_skv_prefix_real(function (p)
                                   self.skvp[p.prefix] = p
                                end)

   -- our rid may have changed -> change that of the pa too, just in case
   self.pa.rid = self.rid

   -- consider if either ospf change occured (we got callback), pa
   -- itself is in turbulent state, or the if state changed
   local r
   if self.pa:should_run() or self.ospf_changes > 0 
   then
      self.ospf_changes = 0
      r = self.pa:run{checked_should=true}
   end

   self:d('pa.run result', r, self.first)
   local ridr_repr = mst.repr(self.pa.ridr)
   local skvp_repr = mst.repr(self.skvp)

   local c1 = ridr_repr ~= self.ridr_repr
   local c2 = skvp_repr ~= self.skvp_repr
   if r or self.first or c1 or c2
   then
      self:d('run doing skv/lsa update',  r, self.first, c1, c2)

      -- raw contents of the interfaces MAY change what we publish,
      -- even if the PA algorithm is still happy! so therefore we consider the
      -- ridr_repr too
      self.ridr_repr = ridr_repr

      -- same with SKV - we may have e.g. different next hop from DHCPv6 PD
      -- that we need to propagate
      self.skvp_repr = skvp_repr

      -- store the rid to SKV too
      self.skv:set(OSPF_RID_KEY, self.rid)

      -- originate LSA (or try to, there's duplicate prevention, or should be)
      local body = self:generate_ac_lsa()
      mst.a(body and #body, 'empty generated LSA?!?')

      self.elsa:originate_lsa{type=AC_TYPE, 
                              rid=self.pa.rid,
                              body=body}

      -- set up the locally assigned prefix field
      local t = mst.array:new()
      for i, lap in ipairs(self.pa.lap:values())
      do
         local ifo = self.pa.ifs[lap.iid]
         if not ifo
         then
            self:d('zombie interface', lap)
         end
         t:insert({ifname=lap.ifname, 
                   prefix=lap.ascii_prefix,
                   depracate=lap.depracated and 1 or nil,
                   owner=lap.owner,
                   address=lap.address and lap.address:get_ascii() or nil,
                  })
      end
      self.skv:set(OSPF_LAP_KEY, t)

      -- set up the interface list
      local t = mst.array:new{}
      for iid, ifo in pairs(self.pa.ifs)
      do
         t:insert(ifo.name)
      end
      self.skv:set(OSPF_IFLIST_KEY, t)

      -- set up the 'all visible DNS servers' field (right now, bit
      -- formless, but oh well)
      self.skv:set(OSPF_DNS_KEY, self:get_dns_array())

      -- similarly search domains
      self.skv:set(OSPF_DNS_SEARCH_KEY, self:get_dnssearch_array())

      -- toss in the usp's too
      local t = mst.array:new{}
      local dumped = mst.set:new{}

      self:d('creating usp list')

      function _dump_usp(usp, debug_source)
         local rid = usp.rid
         local p = usp.ascii_prefix or usp.prefix
         if not dumped[p]
         then
            self:d('got from', debug_source, p)
            dumped:insert(p)
            local r = self.pa:route_to_rid(rid) or {}
            -- nh/ifname are optional (not applicable in case of e.g. self)
            self:d('got route', r)
            
            -- look up the local SKV prefix if available
            -- (pa code doesn't pass-through whole objects, intentionally)
            local n = self.skvp[p] or {}
            local nh = r.nh or n.nh
            local ifname = r.ifname or n.ifname
            t:insert({prefix=p, rid=rid, nh=nh, ifname=ifname})
         end
      end

      for i, v in ipairs(self.pa.usp:values())
      do
         _dump_usp(v, 'pa.usp')
      end

      -- toss also usp's from the LAP, which still live
      for i, lap in ipairs(self.pa.lap:values())
      do
         local usp = lap.asp.usp
         _dump_usp(usp, 'pa.lap')
      end

      self.skv:set(OSPF_USP_KEY, t)
   end
   self.first = false
end

function elsa_pa:iterate_ac_lsa(f, criteria)
   if criteria
   then
      criteria = mst.table_copy(criteria)
   else
      criteria = {}
   end
   criteria.type = AC_TYPE
   self.elsa:iterate_lsa(self.rid, f, criteria)
end

function elsa_pa:iterate_ac_lsa_tlv(f, criteria)
   function inner_f(lsa) 
      for i, tlv in ipairs(codec.decode_ac_tlvs(lsa.body))
      do
         if not criteria or mst.table_contains(tlv, criteria)
         then
            f(tlv, lsa)
         end
      end
   end
   self:iterate_ac_lsa(inner_f)
end

--  iterate_rid(rid, f) => callback with rid
function elsa_pa:iterate_rid(rid, f)
   -- we're always reachable (duh), but no next-hop/if
   f{rid=rid}

   -- the rest, we look at LSADB 
   self:iterate_ac_lsa(function (lsa) 
                          local rid = lsa.rid
                          local r = self.elsa:route_to_rid(rid) or {}
                          f{rid=rid, nh=r.nh, ifname=r.ifname}
                       end)
end

--  iterate_asp(rid, f) => callback with prefix, iid, rid
function elsa_pa:iterate_asp(rid, f)
   self:iterate_ac_lsa_tlv(function (asp, lsa) 
                              self:a(lsa and asp)
                              f{prefix=asp.prefix, iid=asp.iid, rid=lsa.rid}
                           end, {type=codec.AC_TLV_ASP})
end

--  iterate_asa(rid, f) => callback with {prefix=, rid=}
function elsa_pa:iterate_asa(rid, f)
   for i, o in ipairs(self:get_asa_array())
   do
      f{rid=o.rid, prefix=ipv6s.new_prefix_from_ascii(o.prefix)}
   end
end

--  iterate_usp(rid, f) => callback with prefix, rid
function elsa_pa:iterate_usp(rid, f)
   self:iterate_skv_prefix(function (o)
                              f{prefix=o.prefix, 
                                --ifname=o.ifname,
                                --nh=o.nh,
                                rid=rid, 
                               }
                           end)
   self:iterate_ac_lsa_tlv(function (usp, lsa)
                              self:a(lsa and usp)
                              f{prefix=usp.prefix, rid=lsa.rid}
                           end, {type=codec.AC_TLV_USP})
end

--  iterate_if(rid, f) => callback with ifo
function elsa_pa:iterate_if(rid, f)
   local inuse_ifnames = mst.set:new{}

   -- determine the interfaces for which we don't want to provide
   -- interface callback (if we're using local interface-sourced
   -- delegated prefix, we don't want to offer anything there)
   self:iterate_skv_prefix(function (o)
                              local ifname = o.ifname
                              self:d('in use ifname', ifname)
                              inuse_ifnames:insert(ifname)
                           end)

   self.elsa:iterate_if(rid, function (ifo)
                           self.all_seen_if_names:insert(ifo.name)
                           self:a(ifo)
                           if not inuse_ifnames[ifo.name]
                           then
                              f(ifo)
                           else
                              self:d('skipping in use', ifo, 'delegated prefix source')
                           end
                        end)
end

--   iterate_ifo_neigh(rid, if-object, f) => callback with iid, rid
function elsa_pa:iterate_ifo_neigh(rid, ifo, f)
   -- just forward for the time being
   self.elsa:iterate_ifo_neigh(rid, ifo, f)
end


function elsa_pa:iterate_skv_prefix(f)
   for k, v in pairs(self.skvp)
   do
      f(v)
   end
end

function elsa_pa:iterate_skv_prefix_real(f)
   function handle_if(ifname, skvprefix, metric)
      local o = self.skv:get(string.format('%s%s%s', 
                                           skvprefix, PREFIX_KEY, ifname))
      if o
      then
         -- enter to the fallback lottery - the stuff returned by this
         -- should NOT decrease in size
         self.all_seen_if_names:insert(ifname)

         local prefix, valid
         if type(o) == 'string'
         then
            prefix = o
            valid = nil
         else
            prefix, valid = unpack(o)
         end
         local nh
         local o2 = self.skv:get(string.format('%s%s%s', 
                                               skvprefix, NH_KEY, ifname))
         if o2
         then
            self:a(type(o2) == 'string')
            nh = o2
         end
         if not valid or valid >= os.time()
         then
            f{prefix=prefix, ifname=ifname, nh=nh, metric=metric}
         end
      end
   end

   local pdlist = self.skv:get(PD_IFLIST_KEY)
   for i, ifname in ipairs(pdlist or self.all_seen_if_names:keys())
   do
      handle_if(ifname, PD_SKVPREFIX, 1000)
   end
   handle_if(SIXRD_DEV, SIXRD_SKVPREFIX, 2000)
end

function elsa_pa:get_field_array(locala, jsonfield)
   local s = mst.set:new{}
   
   -- get local ones
   for i, addr in ipairs(locala)
   do
      s:insert(addr)
   end

   -- get global ones
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              for i, addr in ipairs(json.table[jsonfield] or {})
                              do
                                 s:insert(addr)
                              end
                           end, {type=codec.AC_TLV_JSONBLOB})


   -- return set as array
   return s:keys()
end

function elsa_pa:get_local_field_array(pdfield)
   local t
   for i, ifname in ipairs(self.all_seen_if_names:keys())
   do
      local o = self.skv:get(string.format('%s%s%s', 
                                           PD_SKVPREFIX, pdfield, ifname))
      if o
      then
         if not t then t = mst.array:new{} end
         t:insert(o)
      end
   end
   return t
end

function elsa_pa:get_local_dns_array()
   return self:get_local_field_array(DNS_KEY) or {}
end

function elsa_pa:get_dns_array()
   return self:get_field_array(self:get_local_dns_array(), 
                               JSON_DNS_KEY)
end

function elsa_pa:get_local_dnssearch_array()
   return self:get_local_field_array(DNS_SEARCH_KEY) or {}
end

function elsa_pa:get_dnssearch_array()
   return self:get_field_array(self:get_local_dnssearch_array(), 
                               JSON_DNS_SEARCH_KEY)
end

function elsa_pa:get_local_asa_array()
   -- bit different than the rest, as this originates within pa code
   -- => what we do, is look at what's within the lap, and toss
   -- non-empty addresses
   local t = mst.array:new{}
   local laps = self.pa.lap:values():filter(function (lap) return lap.address end)
   self:ph_list_sorted(laps)

   for i, lap in ipairs(laps)
   do
      t:insert({rid=self.rid, prefix=lap.address:get_ascii()})
   end
   return t
end

function elsa_pa:get_asa_array()
   return self:get_field_array(self:get_local_asa_array(), 
                               JSON_ASA_KEY)
end

function elsa_pa:ph_list_sorted(l)
   local t = mst.table_copy(l or {})
   table.sort(t, function (o1, o2)
                 return o1.prefix:get_binary() < o2.prefix:get_binary()
                 end)
   return t
end

function elsa_pa:generate_ac_lsa()

   -- adding these in deterministic order is mandatory; however, by
   -- default, the list ISN'T sorted in any sensible way.. so we have
   -- to do it
   self:d('generate_ac_lsa')

   local a = mst.array:new()

   -- generate RHF
   local hwf = self:get_padded_hwf(self.rid)
   self:d(' hwf', hwf)

   a:insert(codec.rhf_ac_tlv:encode{body=hwf})

   -- generate local USP-based TLVs

   local uspl = self:ph_list_sorted(self.pa.usp[self.rid])
   for i, usp in ipairs(uspl)
   do
      self:d(' usp', self.rid, usp.prefix)
      a:insert(codec.usp_ac_tlv:encode{prefix=usp.prefix})
   end

   -- generate (local) ASP-based TLVs
   local aspl = self:ph_list_sorted(self.pa:get_local_asp_values())
   for i, asp in ipairs(aspl)
   do
      self:d(' asp', self.rid, asp.iid, asp.prefix)
      a:insert(codec.asp_ac_tlv:encode{prefix=asp.prefix, iid=asp.iid})
   end

   -- generate 'FYI' blob out of local SKV state; right now, just the
   -- interface-specific DNS information, if any
   local t = mst.map:new{}
   t[JSON_DNS_KEY] = self:get_local_dns_array()
   t[JSON_DNS_SEARCH_KEY] = self:get_local_dnssearch_array()
   t[JSON_ASA_KEY] = self:get_local_asa_array()

   if t:count() > 0
   then
      self:d(' json', t)
      a:insert(codec.json_ac_tlv:encode{table=t})
   end

   if #a
   then
      local s = table.concat(a)
      self:d('generated ac lsa of length', #s)
      return s
   end
end
