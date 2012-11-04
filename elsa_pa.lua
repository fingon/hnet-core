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
-- Last modified: Sun Nov  4 04:23:31 2012 mstenber
-- Edit time:     418 min
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

-- LSA type used for storing the auto-configuration LSA
AC_TYPE=0xBFF0

-- SKV-related things
PD_SKVPREFIX='pd-'
SIXRD_SKVPREFIX='6rd-'
SIXRD_DEV='6rd'

-- used to convey DHCPv4-sourced information
DHCPV4_SKVPREFIX='dhcp-'

-- used to indicate that interface shouldn't be assigned to
DISABLE_SKVPREFIX='disable-pa-'

-- used to indicate that no IPv4 prefix assignment on the interface
DISABLE_V4_SKVPREFIX='disable-pa-v4-'

-- skv key is formed of *_SKVPREFIX + one of these + interface name
PREFIX_KEY='prefix.'
DNS_KEY='dns.'
DNS_SEARCH_KEY='dns-search.'
NH_KEY='nh.'

-- SKV 'singleton' keys
PD_IFLIST_KEY='pd-iflist'
OSPF_RID_KEY='ospf-rid'
OSPF_LAP_KEY='ospf-lap'
OSPF_USP_KEY='ospf-usp'
OSPF_DNS_KEY='ospf-dns'
OSPF_DNS_SEARCH_KEY='ospf-dns-search'
OSPF_IFLIST_KEY='ospf-iflist'
OSPF_IPV4_DNS_KEY='ospf-v4-dns'
OSPF_IPV4_DNS_SEARCH_KEY='ospf-v4-dns-search'

-- JSON fields within jsonblob AC TLV
JSON_ASA_KEY='asa'
JSON_DNS_KEY='dns'
JSON_DNS_SEARCH_KEY='dns-search'
JSON_IPV4_DNS_KEY='ipv4-dns'
JSON_IPV4_DNS_SEARCH_KEY='ipv4-dns-search'

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

local json_sources={[JSON_DNS_KEY]={prefix=PD_SKVPREFIX, 
                                    key=DNS_KEY, 
                                    ospf=OSPF_DNS_KEY},
                    [JSON_DNS_SEARCH_KEY]={prefix=PD_SKVPREFIX, 
                                           key=DNS_SEARCH_KEY, 
                                           ospf=OSPF_DNS_SEARCH_KEY},

                    [JSON_IPV4_DNS_KEY]={prefix=DHCPV4_SKVPREFIX,
                                         key=DNS_KEY, 
                                         ospf=OSPF_IPV4_DNS_KEY},
                    [JSON_IPV4_DNS_SEARCH_KEY]={prefix=DHCPV4_SKVPREFIX,
                                           key=DNS_SEARCH_KEY, 
                                           ospf=OSPF_IPV4_DNS_SEARCH_KEY},
}
                    

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
   -- force first run (repr changes force AC LSA generation; ospf_changes
   -- forces PA alg to be run)
   self.ridr_repr_hash = ''
   self.skvp_repr_hash = ''
   self.ospf_changes = 1
   self.check_skvp = true

   -- create the actual abstract prefix algorithm object we wrap
   self.pa = pa.pa:new{rid=self.rid, client=self, lap_class=elsa_lap,
                       new_prefix_assignment=self.new_prefix_assignment,
                       new_ula_prefix=self.new_ula_prefix}

   -- set of _all_ interface names we've _ever_ seen (used for
   -- checking SKV for tidbits)
   self.all_seen_if_names = mst.set:new{}

   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)
end

function elsa_pa:uninit()
   self.skv:remove_change_observer(self.f)

   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state, which is basically the pa object
   self.pa:done()
end

function elsa_pa:kv_changed(k, v)
   -- should check skv the next time we've run
   self.check_skvp = true
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

function elsa_pa:should_run()
   -- ! important to check pa.should_run() first, even if it's
   -- inefficient; we never call should_run() within pa.run(), and
   -- it's needed to get pa.run() to sane state..
   if self.pa:should_run()
   then
      -- debug message provided by self.pa..
      return true
   end
   if self.ospf_changes > 0
   then
      mst.d('should run - ospf changes pending', self.ospf_changes)
      return true
   end
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
   
   if self.check_skvp
   then
      self:update_skvp()
   end

   -- our rid may have changed -> change that of the pa too, just in case
   self.pa.rid = self.rid

   -- consider if either ospf change occured (we got callback), pa
   -- itself is in turbulent state, or the if state changed
   local r
   if self:should_run()
   then
      self.ospf_changes = 0
      r = self.pa:run{checked_should=true}
      self:d('pa.run result', r)
   end

   local s_repr = table.concat{mst.repr{self.pa.ridr}, self.skvp_repr}

   if r or s_repr ~= self.s_repr
   then
      self:d('run doing skv/lsa update',  r)

      -- store the current local state
      self.s_repr = s_repr

      self:run_handle_new_lsa()

      self:run_handle_skv_publish()
   end
   self:d('run done')
end

function elsa_pa:run_handle_new_lsa()
   -- originate LSA (or try to, there's duplicate prevention, or should be)
   local body = self:generate_ac_lsa()
   mst.a(body and #body, 'empty generated LSA?!?')

   self.elsa:originate_lsa{type=AC_TYPE, 
                           rid=self.rid,
                           body=body}

end

function elsa_pa:run_handle_skv_publish()
   -- store the rid to SKV too
   self.skv:set(OSPF_RID_KEY, self.rid)

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

   -- handle assorted 'gather info across the net' fields
   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      self.skv:set(o.ospf, self:get_field_array(l, jsonkey))
   end

   -- toss in the usp's too
   local t = mst.array:new{}
   local dumped = mst.set:new{}

   self:d('creating usp list')
   for i, usp in ipairs(self.pa.usp:values())
   do
      local rid = usp.rid
      local p = usp.ascii_prefix
      if not dumped[p]
      then
         self:d(' usp', p)
         dumped:insert(p)
         -- no route info for ula/ipv4 prefixes
         if usp.prefix:is_ula() or usp.prefix:is_ipv4()
         then
            t:insert({prefix=p, rid=rid})
         else
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
   end
   self.skv:set(OSPF_USP_KEY, t)
end

function elsa_pa:iterate_ac_lsa(f, criteria)
   criteria = criteria or {}

   -- make sure this object isn't being reused - 
   -- we intentionally minimize number of copies, but if there
   -- is type selector already, this is a second call with same table
   -- (and potentially problematic)
   mst.a(not criteria.type)

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
                          local r = self.elsa:route_to_rid(self.rid, rid) or {}
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
                           if inuse_ifnames[ifo.name]
                           then
                              self:d('skipping in use', ifo, 'delegated prefix source')
                              return
                           end
                           -- set up the static variable on the ifo
                           ifo.disable = self.skv:get(DISABLE_SKVPREFIX .. ifo.name)
                           ifo.disable_v4 = self.skv:get(DISABLE_V4_SKVPREFIX .. ifo.name)
                           f(ifo)
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

function elsa_pa:update_skvp()
   self.check_skvp = nil
   self.skvp = mst.map:new()
   self:iterate_skv_prefix_real(function (p)
                                   self.skvp[p.prefix] = p
                                end)
   self.skvp_repr = mst.repr(self.skvp)
end

function elsa_pa:iterate_skv_if_real(ifname, skvprefix, metric, f)
   local o = self.skv:get(string.format('%s%s%s', 
                                        skvprefix, PREFIX_KEY, ifname))
   if not o
   then
      return
   end
   -- enter to the fallback lottery - the interface set we check
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

function elsa_pa:iterate_skv_pd_prefix_real(f)
   local pdlist = self.skv:get(PD_IFLIST_KEY)
   for i, ifname in ipairs(pdlist or self.all_seen_if_names:keys())
   do
      self:iterate_skv_if_real(ifname, PD_SKVPREFIX, 1000, f)
   end
end


function elsa_pa:iterate_skv_prefix_real(f)
   self:iterate_skv_pd_prefix_real(f)
   self:iterate_skv_if_real(SIXRD_DEV, SIXRD_SKVPREFIX, 2000, f)
end

function elsa_pa:get_field_array(locala, jsonfield)
   local s = mst.set:new{}
   
   -- get local ones
   for i, v in ipairs(locala or {})
   do
      s:insert(v)
   end

   -- get global ones
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              for i, v in ipairs(json.table[jsonfield] or {})
                              do
                                 s:insert(v)
                              end
                           end, {type=codec.AC_TLV_JSONBLOB})


   -- return set as array
   -- XXX - does the order matter? hope not!
   return s:keys()
end

function elsa_pa:get_local_field_array(prefix, field)
   local t
   for i, ifname in ipairs(self.all_seen_if_names:keys())
   do
      local o = self.skv:get(string.format('%s%s%s', 
                                           prefix, field, ifname))
      if o
      then
         if not t then t = mst.array:new{} end
         t:insert(o)
      end
   end
   return t
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
   return self:get_field_array(self:get_local_asa_array(), JSON_ASA_KEY)
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

   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      t[jsonkey] = l
   end
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
