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
-- Last modified: Thu Oct 31 11:36:32 2013 mstenber
-- Edit time:     1133 min
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

-- TODO - document the API between elsa (wrapper), elsa_pa

-- => lsa_changed(lsa)
-- => lsa_deleting(lsa)
-- <= ???

require 'mst'
require 'mst_skiplist'
require 'ospf_codec'
require 'ssloop'
require 'dns_db' -- for name2ll

local pa = require 'pa'

module(..., package.seeall)

-- LSA type used for storing the auto-configuration LSA
-- Benjamin
--AC_TYPE=0xBFF0

-- 0xAC0F Jari
AC_TYPE=0xAC0F

FORCE_SKV_AC_CHECK_INTERVAL=60

-- New scheme for encoding the received PD/6RD/DHCPv4 in the SKV is as
-- follows:

-- <source>.<ifname> = { {key1=value1, key2=value2}, {key3=value3, key4=value4, ..} }

PD_SKVPREFIX='pd.'
DHCPV4_SKVPREFIX='dhcp.'
TUNNEL_SKVPREFIX='tunnel.'

SKVPREFIXES={PD_SKVPREFIX, DHCPV4_SKVPREFIX, TUNNEL_SKVPREFIX}

-- these keys are used within the objects to describe found information
PREFIX_KEY='prefix'
DNS_KEY='dns'
DNS_SEARCH_KEY='dns_search'
NH_KEY='nh'
IFLIST_KEY='iflist' -- allow overriding of active interfaces for source type

-- extra info fields not used directly, but used in e.g. pm handlers
PREFIX_CLASS_KEY='pclass'
PREFERRED_KEY='pref' -- both of these are absolute timestamps
VALID_KEY='valid'

-- list of keys which are passed verbatim from 
-- IF-specific prefix SKV [=> JSON_USP_INFO_KEY] => LAP/USP SKV lists
PREFIX_INFO_SKV_KEYS={PREFIX_CLASS_KEY}

-- locally as-is passed fields
PREFIX_INFO_LOCAL_SKV_KEYS={PREFERRED_KEY, VALID_KEY}

-- used to indicate that interface shouldn't be assigned to (nor used
-- in general - this includes starting any daemon on it)
DISABLE_SKVPREFIX='disable.'

-- used to indicate that no IPv4 prefix assignment on the interface
DISABLE_V4_SKVPREFIX='disable-pa-v4.'

-- SKV 'singleton' keys
OSPF_RID_KEY='ospf-rid' -- OSPF router ID
OSPF_RNAME_KEY='ospf-rname' -- (home-wide unique) router name

OSPF_LAP_KEY='ospf-lap' -- PA alg locally assigned prefixes (local)
OSPF_USP_KEY='ospf-usp' -- usable prefixes from PA alg (across whole home)
OSPF_IFLIST_KEY='ospf-iflist' -- active set of interfaces
-- IPv6 DNS 
OSPF_DNS_KEY='ospf-dns' 
OSPF_DNS_SEARCH_KEY='ospf-dns-search'
-- IPv4 DNS 
OSPF_IPV4_DNS_KEY='ospf-v4-dns'
OSPF_IPV4_DNS_SEARCH_KEY='ospf-v4-dns-search'

-- allow for configuration of prefix assignment algorithm
-- via skv too
PA_CONFIG_SKV_KEY='pa-config'

-- JSON fields within jsonblob AC TLV
JSON_ASA_KEY='asa' -- assigned IPv4 address
JSON_DNS_KEY='dns'
JSON_DNS_SEARCH_KEY='dns_search'
JSON_IPV4_DNS_KEY='ipv4_dns'
JSON_IPV4_DNS_SEARCH_KEY='ipv4_dns_search'

-- extra USP information
JSON_USP_INFO_KEY='usp_info'

-- Hybrid proxy specific things

-- Zones consist of:
-- name=<name>, ip=<ip>[, browse=<something][, search=<something>]

-- note that name is UTF-8 string ('foo.bar.com'). this could be done
-- with label lists if we cared enough..

-- ip is where the responsible name server can be reached within (or
-- without) home

-- browse being set indicates that the zone is ~local, and it should
-- be added to the DNS-SD browse path

-- search being set indicates that the zone is ~remote, and it should
-- be added to the DHCP{v4,v6} and RA search list


-- these two are set by user (and come through elsa_pa to hybrid
-- proxy)
STATIC_HP_DOMAIN_KEY='static-domain' -- <name>
STATIC_HP_ZONES_KEY='static-zones' -- manually added extra remote zones

-- this is provided by hybrid proxy _to_ OSPF
HP_MDNS_ZONES_KEY='hp-mdns-zones' -- local autodiscovered mdns zones
-- (populated by hp_ospf)

-- and this to PM for local DHCP/RA server usage
HP_SEARCH_LIST_KEY='hp-search' -- to be published via DHCP*/RA

-- these are provided by OSPF _to_ hybrid proxy
OSPF_HP_DOMAIN_KEY='ospf-hp-domain' -- <name>
OSPF_HP_ZONES_KEY='ospf-hp-zones' -- non-local hybrid proxy zones

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

ORIGINATE_MIN_INTERVAL=4 -- up to this point, we hold on spamming
ORIGINATE_MAX_INTERVAL=300 -- even without changes

-- TODO - TERMINATE_ULA_PREFIX timeout is a 'SHOULD', but we ignore it
-- for simplicity's sake; getting rid of floating prefixes ASAP is
-- probably good thing (and the individual interface-assigned prefixes
-- will be depracated => will disappear soon anyway)

-- what do we mirror ~directly to OSPF?
skv_to_ospf_set = mst.array_to_table{
   STATIC_HP_DOMAIN_KEY,
   STATIC_HP_ZONES_KEY,
   HP_SEARCH_LIST_KEY,
                                    }

-- elsa specific lap subclass
elsa_lap = pa.lap:new_subclass{class='elsa_lap',
                              }

local json_sources={
   [JSON_DNS_SEARCH_KEY]={prefix=PD_SKVPREFIX, 
                          key=DNS_SEARCH_KEY, 
                          ospf=OSPF_DNS_SEARCH_KEY},

   [JSON_IPV4_DNS_SEARCH_KEY]={prefix=DHCPV4_SKVPREFIX,
                               key=DNS_SEARCH_KEY, 
                               ospf=OSPF_IPV4_DNS_SEARCH_KEY},
}

function elsa_lap:start_depracate_timeout()
   self:d('start_depracate_timeout')
   self:a(not self.timeout)
   self.timeout = self.pa.time() + LAP_DEPRACATE_TIMEOUT
   self.pa.timeouts:insert(self)
end

function elsa_lap:stop_depracate_timeout()
   self:d('stop_depracate_timeout')
   self:a(self.timeout)
   self.pa.timeouts:remove_if_present(self)
   self.timeout = nil
end

function elsa_lap:start_expire_timeout()
   self:d('start_expire_timeout')
   self:a(not self.timeout)
   self.timeout = self.pa.time() + LAP_EXPIRE_TIMEOUT
   self.pa.timeouts:insert(self)
end

function elsa_lap:stop_expire_timeout()
   self:d('stop_expire_timeout')
   self:a(self.timeout)
   self.pa.timeouts:remove_if_present(self)
   self.timeout = nil
end


-- actual elsa_pa itself, which controls pa (and interfaces with
-- skv/elsa-wrapper
elsa_pa = mst.create_class{class='elsa_pa', 
                           mandatory={'skv', 'elsa', 'if_table'},
                           time=ssloop.time,
                           originate_min_interval=ORIGINATE_MIN_INTERVAL,
                          }

function elsa_pa:init()
   -- set of _all_ interface names we've _ever_ seen (used for
   -- checking SKV for tidbits). initialized only here so that it
   -- won't be screwed if pa reconfigure is called.

   self.all_seen_if_names = mst.set:new{}

   self.f = function (k, v) self:kv_changed(k, v) end
   self.skv:add_change_observer(self.f)

   -- overridable fields either using arguments to this class,
   -- or using the 'o' dict (priority-wise, o > class > defaults)
   local args = {new_prefix_assignment=NEW_PREFIX_ASSIGNMENT,
                 new_ula_prefix=NEW_ULA_PREFIX,
   }

   for i, v in ipairs(pa.CONFIGS)
   do
      args[v] = false
   end

   -- check if class has updates on any of the keys..
   for k, v in pairs(args)
   do
      local v2 = self[k]
      if v2
      then
         args[k] = v2
      end
   end

   self.pa_args = args

   -- this should not be done before we actually have pa_config from skv
   -- however, someone may have supplied us pa_config as argument
   self.pa_config = self.pa_config or self.skv:get(PA_CONFIG_SKV_KEY)
   self:reconfigure_pa()
end

function elsa_pa:reconfigure_pa(v)
   self:d('reconfigure_pa')
   v = v or self.pa_config
   self.pa_config = v
   self:init_own()
   if not v
   then
      self:d(' skipped, no config yet')
      return 
   end
   self:init_pa()
end

function elsa_pa:init_own()
   -- set various things to their default values
   self.ac_changes = 0
   self.lsa_changes = 0
   self.skv_changes = 0

   -- when did we consider originate/publish last
   self.last_publish = 0

   -- when did we last actually originate AC LSA
   self.last_originate = 0
   -- and what did it contain?
   self.last_body = ''
end

local function timeout_is_less(o1, o2)
   return o1.timeout < o2.timeout
end

function elsa_pa:init_pa()
   local args = mst.table_copy(self.pa_args)

   -- update with whatever we have in pa_config
   mst.table_copy(self.pa_config, args)

   -- these are always hardcoded - nobody should be able to change them
   args.rid=self.rid
   args.client = self
   args.lap_class = elsa_lap
   args.time = self.time

   -- create the actual abstract prefix algorithm object we wrap
   -- (create shallow copy of args, so that we don't wind up re-using
   -- the object)
   self.pa = pa.pa:new(mst.table_copy(args))
   self.pa.timeouts = mst_skiplist.ipi_skiplist:new{p=2,
                                                    lt=timeout_is_less}
end

function elsa_pa:uninit()
   self.skv:remove_change_observer(self.f)

   if self.pa
   then
      -- we don't 'own' skv or 'elsa', so we don't do anything here,
      -- except clean up our own state, which is basically the pa object
      self.pa:done()
   end
end

function elsa_pa:kv_changed(k, v)
   -- handle configuration changes explicitly here
   if k == PA_CONFIG_SKV_KEY
   then
      self:reconfigure_pa(v)
      return
   end
   
   if skv_to_ospf_set[k]
   then
      self.skv_changes = self.skv_changes + 1
   end

   -- implicitly externally sourced information to the
   -- all_seen_if_names (someone plays with stuff that starts with
   -- one of the skvprefixes -> stuff happens)

   for i, p in ipairs(SKVPREFIXES)
   do
      local r = mst.string_startswith(k, p)
      if r
      then
         if r ~= IFLIST_KEY
         then
            self:add_seen_if(r)
         end
         break
      end
   end

   -- TODO - determine which cases should actually do this?
   -- invalidate caches that have if info
   self.skvp = nil
   self.ext_set = nil
end

function elsa_pa:lsa_changed(lsa)
   local lsatype = lsa.type
   if lsa.rid == self.rid
   then
      -- ignore us, if BIRD calls us about it.. we don't
      -- 'see' our own changes
      return
   end
   self.ac_tlv_cache = nil
   self.rid2ro = nil
   if lsatype == AC_TYPE
   then
      self:d('ac lsa changed at', lsa.rid)
      self.ac_changes = self.ac_changes + 1
   else
      self:d('other lsa changed at', lsa.rid, lsatype)
      self.lsa_changes = self.lsa_changes + 1
   end
end

function elsa_pa:lsa_deleting(lsa)
   -- for the time being, we don't note a difference between the two
   self:lsa_changed(lsa)
end

function elsa_pa:ospf_changed()
   -- emulate to get the old behavior.. shouldn't be called!
   self:d('deprecated ospf_changed called')
   self:lsa_changed{type=AC_TYPE}
   self:lsa_changed{type=(AC_TYPE-1)}
end

function elsa_pa:repr_data()
   return '-'
end

function elsa_pa:get_rname_base()
   local n = mst.read_filename_to_string('/proc/sys/kernel/hostname') or 'r'
   n = mst.string_strip(n)
   self:d('get_rname_base', n)
   return n
end

function elsa_pa:get_hwaddr(rid, ifname)
   local ifo = self.if_table:get_if(ifname)
   if ifo
   then
      return ifo:get_hwaddr()
   end
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
   local d = ospf_codec.MINIMUM_AC_TLV_RHF_LENGTH
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
   local function consider_lsa(lsa)
      lsas = lsas + 1
      if lsa.rid ~= self.rid then return end
      local found = nil
      for i, tlv in ipairs(ospf_codec.decode_ac_tlvs(lsa.body))
      do
         tlvs = tlvs + 1
         if tlv.type == ospf_codec.AC_TLV_RHF
         then
            found = tlv.body
         end
      end
      if found and found ~= my_hwf
      then
         other_hwf = found
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

   self.ac_changes = 0
   self.lsa_changes = 0

   self.had_conflict = true

   return true
end

-- API to check from outside if run() should be called yet (strict
-- test runner won't call it unless it has to; however, in case of
-- elsa stuff, we typically call it in tick() functions or so so this
-- is mostly useful for unit testing)
function elsa_pa:should_run()
   -- no pa? no point
   if not self.pa
   then
      return
   end

   local lap = self.pa.timeouts:get_first()
   if lap and lap.timeout <= self.time() 
   then 
      self:d('should run due to lap.timeout')
      return true 
   end
   if self:should_run_pa()
   then
      return true
   end
   return self:should_publish{ac_changes=self.ac_changes, 
                              lsa_changes=self.lsa_changes}
end

function elsa_pa:should_run_pa()
   -- first local reasons we know of
   if self.ac_changes > 0
   then
      self:d('should_run_pa, ac_changes > 0')
      return true
   end

   -- skvp change indicates we should also run PA
   local _, skvp_repr = self:get_skvp()
   if skvp_repr ~= self.pa_skvp_repr
   then
      self:d('should_run_pa, skvp changed')
      return true
   end

   -- then the pa itself (second argument is checked_should)
   if self.pa:should_run()
   then
      return true, true
   end
end

function elsa_pa:next_time()
   if not self.pa
   then
      return
   end
   if self:should_run()
   then
      return 0
   end
   -- there are two cases:
   -- - either delayed publish (self.last_publish == 0)
   -- or
   -- - timeout
   local lap = self.pa.timeouts:get_first()
   local nt
   if lap then nt = lap.timeout end
   if self.last_publish == 0
   then
      local next = self.last_originate + self.originate_min_interval
      if not nt or nt > next
      then
         nt = next
      end
   end
   return nt
end



function elsa_pa:should_publish(d)
   local r

   -- if pa.run() said there's changes, yep, we should
   if d.r 
   then 
      self:d('should publish due to d.r')
      r = r or {}
   end

   if self.ridr_repr ~= self.publish_ridr_repr
   then
      r = r or {}
      r.publish_ridr_repr = self.ridr_repr
      self:d('should publish, ridr_repr changed')
   end

   local _, skvp_repr = self:get_skvp()
   if skvp_repr ~= self.publish_skvp_repr
   then
      r = r or {}
      r.publish_skvp_repr = skvp_repr
      self:d('should publish, skvp_repr changed')
   end

   -- if ac LSA changed we should
   if d.ac_changes and d.ac_changes > 0 
   then 
      self:d('should publish state due to ac_changes > 0')
      r = r or {}
   end
   -- also if non-ac LSA changes, we should
   if d.lsa_changes and d.lsa_changes > 0 
   then 
      self:d('should publish state due to lsa_changes > 0')
      r = r or {}
   end
   
   if self.skv_changes > 0
   then
      self:d('should publish state due to skv_changes > 0')
      r = r or {}
      r.skv_changes = 0
   end

   -- finally, if the FORCE_SKV_AC_CHECK_INTERVAL was passed, we do
   -- this (but this is paranoia, shouldn't be necessary)
   if  (self.time() - self.last_publish) > FORCE_SKV_AC_CHECK_INTERVAL 
   then 
      self:d(' should publish state due to FORCE_SKV_AC_CHECK_INTERVAL exceeded', self.time(), self.last_publish)
      self.rid2ro = nil
      r = r or {}
   end

   if r
   then
      local now = self.time()
      local delta = now - self.last_originate
      -- don't spam, but ensure we publish as soon as interval is done
      -- by setting the last_publish to 0
      if delta < self.originate_min_interval
      then
         if self.last_publish and self.last_publish > 0
         then
            self:d(' .. but avoidin publish due to spam limitations')
            self.last_publish = 0
         end
         r = nil
      end
   end

   return r
end

function elsa_pa:run()
   self:d('run starting')

   -- without pa, there is no point
   if not self.pa
   then
      return
   end

   local now = self.time()
   while true
   do
      local lap = self.pa.timeouts:get_first()
      if not lap or lap.timeout > now then break end
      -- run the timeout (should remove itself, hopefully?)
      lap.sm:Timeout()
   end

   -- let's check first that there is no conflict; that is,
   -- nobody else with different hw fingerprint, but same rid
   --
   -- if someone like that exists, either we (or they) have to change
   -- their router id..
   if self.ac_changes == 0 
   then
      if self.had_conflict
      then
         self:d('had conflict, no changes => still have conflict')
         return
      end
   else
      if self:check_conflict() then return end
   end

   local run_pa, checked_should = self:should_run_pa()
   local ac_changes = self.ac_changes
   local lsa_changes = self.lsa_changes
   self.ac_changes = 0
   self.lsa_changes = 0

   -- our rid may have changed -> change that of the pa too, just in case
   self.pa.rid = self.rid

   -- consider if either ospf change occured (we got callback), pa
   -- itself is in turbulent state, or the if state changed
   local r
   if run_pa
   then
      r = self.pa:run{checked_should=checked_should}
      self:d('pa.run result', r)
      self.ridr_repr = mst.repr(self.pa.ridr)
      local _, skvp_repr = self:get_skvp()
      self.pa_skvp_repr = skvp_repr
   end

   local now = self.time()

   local sp = self:should_publish{r=r, ac_changes=ac_changes, lsa_changes=lsa_changes}
   if sp
   then
      self.last_publish = self.time()
      
      self:d('run doing skv/lsa update',  r)

      -- store the changed local state
      for k, v in pairs(sp)
      do
         self[k] = v
      end

      self:run_handle_new_lsa()

      -- store the domain; by default, static one, but also one from OSPF
      -- if we don't have static
      local domain = self.skv:get(STATIC_HP_DOMAIN_KEY)
      local domainrid
      if not domain
      then
         self:iterate_ac_lsa_tlv(function (o, lsa)
                                    self:d('dn', o)
                                    if not domain or domainrid < lsa.rid
                                    then
                                       domain = o.domain
                                       domainrid = lsa.rid
                                    end
                                 end, {type=ospf_codec.AC_TLV_DN})

         self:d('remote domain', domain)
      else
         self:d('found local domain', domain)
      end
      self.hp_domain = domain

      self:run_handle_skv_publish()
   end
   self:d('run done')
end

function elsa_pa:run_handle_new_lsa()
   -- originate LSA (or try to, there's duplicate prevention, or should be)
   local body = self:generate_ac_lsa(false)
   mst.a(body and #body, 'empty generated LSA?!?')
   local now = self.time()

   -- send duplicate if and only if we haven't sent anything in a long
   -- while
   if body == self.last_body
   then
      local delta = now - self.last_originate
      if delta < ORIGINATE_MAX_INTERVAL
      then
         return
      end
   end
   -- store the old 'reference' body for further use
   -- (the new body is generated with relative timestamps, and is _always_
   -- different, so not worth storing..)
   self.last_body = body
   
   local body = self:generate_ac_lsa(true)

   self:d('originating ac lsa for real')

   self.last_originate = now

   self.elsa:originate_lsa{type=AC_TYPE, 
                           rid=self.rid,
                           body=body}

end

local function non_empty(x)
   if not x then return end
   local t = type(x)
   if t == 'number' then return x end
   mst.a(t == 'string', 'non-string', t, x)
   if #x == 0 then return end
   return x
end

function relative_to_absolute(v, o_lsa, now)
   mst.a(now, 'no now')
   if not v then return end
   v = v + now - (o_lsa and o_lsa.age or 0)
   return math.floor(v)
end

function absolute_to_relative(v, now)
   mst.a(now, 'no now')
   if not v then return end
   v = v - now
   return math.floor(v)
end

-- gather local and remote prefix information
-- local == what's in skvprefix - prefix string -> object mapping
-- remote == what's in JSON_USP_INFO_KEY jsonblobs of LSAs
function elsa_pa:gather_prefix_info()
   local i1 = {}
   local i2 = {}
   self:iterate_skv_prefix(function (p)
                              if p.prefix 
                              then
                                 i1[p.prefix] = p
                              end
                           end)
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              local t = json.table
                              local h = t[JSON_USP_INFO_KEY]
                              
                              if not h then return end
                              for p, v in pairs(h)
                              do
                                 i2[p] = v
                              end
                           end,
                           {type=ospf_codec.AC_TLV_JSONBLOB})
   return {i1, i2}
end

function elsa_pa:copy_prefix_info_to_o(pi, prefix, dst)
   self:a(type(prefix) == 'string', 'non-string prefix', prefix)
   self:d('copy_prefix_info_to_o', prefix)

   -- given ascii USP prefix p, we have to find the 'extra'
   -- information about it, and dump it to object o

   -- two options: 
   -- - local skv prefix
   -- - 'some' jsonblob AC TLV with the information we want
   local o
   local o_lsa
   local v = pi[1][prefix]
   if v
   then
      o = v
   else
      local v = pi[2][prefix]
      if v
      then
         o = v
         o_lsa = v
      end
   end
   if not o then return end
   for _, key in ipairs(PREFIX_INFO_SKV_KEYS)
   do
      dst[key] = o[key]
   end
   if not o_lsa
   then
      -- this is local information, copy it verbatim
      for _, key in ipairs(PREFIX_INFO_LOCAL_SKV_KEYS)
      do
         dst[key] = o[key]
      end
   else
      -- we have an LSA => it's remote one.  for the time being, we
      -- mainly deal with timestamps, which should be _relative_ in
      -- OSPF, but _locally_ they're absolute. convert them at this
      -- point in time.
      local now = self.time()
      dst[PREFERRED_KEY] = relative_to_absolute(o[PREFERRED_KEY], o_lsa, now)
      dst[VALID_KEY] = relative_to_absolute(o[VALID_KEY], o_lsa, now)
   end
end

function elsa_pa:find_usp_for_ascii_prefix(p, iid)
   local asp = self.pa:get_asp(p, iid, self.rid)
   if asp and asp.usp
   then
      return asp.usp
   end

   -- failure.. look at all usp's instead, and see which one this
   -- prefix belongs to (this is brute-force, but oh well)
   local o
   p = ipv6s.new_prefix_from_ascii(p)
   self.pa.usp:foreach(function (rid, usp)
                          self:a(usp.prefix, 'no prefix?', usp)
                          if usp.prefix:contains(p)
                          then
                             o = usp
                          end
                       end)
   return o
end

function elsa_pa:run_handle_skv_publish()
   -- store the rid to SKV too
   self.skv:set(OSPF_RID_KEY, self.rid)

   -- store own router name
   self.skv:set(OSPF_RNAME_KEY, self.pa.rname)

   -- store the hp domain (if any)
   self.skv:set(OSPF_HP_DOMAIN_KEY, self.hp_domain)

   -- set up the locally assigned prefix field
   local t = mst.array:new()
   local dumped_if_ipv4 = {}
   local pi = self:gather_prefix_info()

   for i, lap in ipairs(self.pa.lap:values())
   do
      local iid = lap.iid
      local ifo = self.pa.ifs[iid]
      if not ifo
      then
         self:d('zombie interface', lap)
         ifo = {}
      end
      if lap.ipv4 and lap.address
      then
         self:a(not dumped_if_ipv4[lap.ifname],
                'system state somehow screwed up [>1 v4 address per if] ',
                self.pa.usp, self.pa.asp, self.pa.lap)
         dumped_if_ipv4[lap.ifname] = true
      end
      local p = lap.ascii_prefix
      local o = {ifname=lap.ifname, 
                 prefix=p,
                 iid=iid,
                 depracate=lap.depracated and 1 or nil,
                 owner=lap.owner,
                 address=lap.address and mst.string_split(lap.address:get_ascii(), '/')[1] or nil,
                 external=ifo.external,
      } 
      local usp = self:find_usp_for_ascii_prefix(p, iid)
      if usp
      then
         local p2 = usp.ascii_prefix
         self:a(p2, 'no ascii_prefix in usp')
         self:copy_prefix_info_to_o(pi, p2, o)
      else
         self:d('no usp?', lap)
      end
      t:insert(o)
   end
   self.skv:set(OSPF_LAP_KEY, t)

   -- set up the interface list
   local t = mst.array:new{}
   for iid, ifo in pairs(self.pa.ifs)
   do
      -- if it's disabled interface, don't let pm know about it either
      if not ifo.disable
      then
         t:insert(ifo.name)
      end
   end
   self.skv:set(OSPF_IFLIST_KEY, t)

   -- handle assorted 'gather info across the net' fields
   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      self.skv:set(o.ospf, self:get_field_array(jsonkey, l))
   end

   -- handle name servers

   -- V4+V6
   local l4, l6 
   l6 = self:get_local_field_array(PD_SKVPREFIX, DNS_KEY, l6)
   l6 = self:get_local_field_array(TUNNEL_SKVPREFIX, DNS_KEY, l6)
   l4 = self:get_local_field_array(DHCPV4_SKVPREFIX, DNS_KEY)
   self:iterate_ac_lsa_tlv(function (o, lsa)
                              local is_ipv4 = ipv6s.address_is_ipv4(o.address)
                              --self:d('see ds', o, is_ipv4)
                              if is_ipv4
                              then
                                 l4 = l4 or {}
                                 table.insert(l4, o.address)
                              else
                                 l6 = l6 or {}
                                 table.insert(l6, o.address)
                              end
                           end, {type=ospf_codec.AC_TLV_DS})
   l4 = mst.array_unique(l4)
   l6 = mst.array_unique(l6)
   self.skv:set(OSPF_DNS_KEY, l6)
   self.skv:set(OSPF_IPV4_DNS_KEY, l4)

   -- XXX - handle search domains for real (we fallback to
   -- json_sources for now for search domain)

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
         local o = {prefix=p, rid=rid}
         if usp.prefix:is_ula() or usp.prefix:is_ipv4()
         then
            -- no route info for ula/ipv4 prefixes
         else
            -- look up the local SKV prefix if available
            -- (pa code doesn't pass-through whole objects, intentionally)
            local skvp = self:get_skvp()
            local n = skvp[p]
            if not n or not n.ifname
            then
               n = self:route_to_rid(rid) or {}
            end
            o.nh = non_empty(n.nh)
            o.ifname = n.ifname
         end
         self:copy_prefix_info_to_o(pi, p, o)
         t:insert(o)
      end
   end
   self.skv:set(OSPF_USP_KEY, t)

   -- also provide the hybrid proxy zones as a list
   -- (who they are from shouldn't matter, they should be self-contained)
   local zones = mst.table_copy(self.skv:get(STATIC_HP_ZONES_KEY) or {})
   self:iterate_ac_lsa_tlv(function (o, lsa)
                              local n = dns_db.ll2name(o.zone)
                              local a = o.address
                              -- zeroed out => no IP -> use global resolving
                              if a == '::'
                              then
                                 a = nil
                              end
                              table.insert(zones,
                                           {
                                              ip=a,
                                              name=n,
                                              search=o.s,
                                              browse=o.b,
                                           })
                           end,
                           {type=ospf_codec.AC_TLV_DDZ})
   self.skv:set(OSPF_HP_ZONES_KEY, zones)
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

function elsa_pa:iterate_ac_lsa_tlv_all_raw(f)
   local function inner_f(lsa) 
      -- don't bother with own rid
      if lsa.rid == self.rid
      then
         return
      end
      xpcall(function ()
                for i, tlv in ipairs(ospf_codec.decode_ac_tlvs(lsa.body))
                do
                   f(tlv, lsa)
                end
             end,
             function (...)
                if mst.enable_debug
                then
                   --print(debug.traceback())
                   mst.debug_print('!!! lsa body handling failed', ...)
                   mst.debug_print('invalid lsa in hex', lsa.rid, lsa.type, mst.string_to_hex(lsa.body))
                end
             end)
   end
   self:iterate_ac_lsa(inner_f)
end

function elsa_pa:iterate_ac_lsa_tlv_all(f)
   if not self.ac_tlv_cache or not self.ac_tlv_cache.all
   then
      local l = {}
      self.ac_tlv_cache = self.ac_tlv_cache or {}
      self:iterate_ac_lsa_tlv_all_raw(function (...)
                                         table.insert(l, {...})
                                      end)
      self.ac_tlv_cache.all = l
      self:d('updated ac_tlv_cache.all')
   end
   for i, v in ipairs(self.ac_tlv_cache.all)
   do
      f(unpack(v))
   end
end

function elsa_pa:iterate_ac_lsa_tlv(f, criteria)
   -- this is a caching call; based on criteria, we remember things in 
   -- ac_tlv_cache until LSAs change, and then it's reset again
   local k = mst.repr(criteria)
   if not self.ac_tlv_cache or not self.ac_tlv_cache[k]
   then
      self.ac_tlv_cache = self.ac_tlv_cache or {}
      local l = {}
      self:iterate_ac_lsa_tlv_all(function (tlv, lsa)
                                     if not criteria or mst.table_contains(tlv, criteria)
                                     then
                                        table.insert(l, {tlv, lsa})
                                     end
                                  end)
      self.ac_tlv_cache[k] = l
      self:d('updated ac_tlv_cache', k)
   end
   for i, v in ipairs(self.ac_tlv_cache[k])
   do
      f(unpack(v))
   end
end

-- get route to the rid, if any
function elsa_pa:route_to_rid(rid)
   -- use 'false' to keep track of failed routing attempts
   self.rid2ro = self.rid2ro or {}
   local v = self.rid2ro[rid]
   if v == nil
   then
      v = self.elsa:route_to_rid(self.rid, rid) or {}
      v = v or false
      self.rid2ro[rid] = v
   end
   return v or nil
end

--  iterate_rid(rid, f) => callback with rid
function elsa_pa:iterate_rid(rid, f)
   -- get a map of rid => rname
   local rid2rname = {}
   self:iterate_ac_lsa_tlv(function (o, lsa)
                              rid2rname[lsa.rid] = o.name
                           end, {type=ospf_codec.AC_TLV_RN})

   -- we're always reachable (duh), but no next-hop/if
   f{rid=rid, rname=self.pa.rname}

   -- the rest, we look at LSADB 
   self:iterate_ac_lsa(function (lsa) 
                          f{rid=lsa.rid, rname=rid2rname[lsa.rid]}
                       end)
end

--  iterate_asp(rid, f) => callback with prefix, iid, rid
function elsa_pa:iterate_asp(rid, f)
   self:iterate_ac_lsa_tlv(function (asp, lsa) 
                              self:a(lsa and asp)
                              self:a(rid ~= lsa.rid, 'own asp in iterate?')
                              f{prefix=asp.prefix, iid=asp.iid, rid=lsa.rid}
                           end, {type=ospf_codec.AC_TLV_ASP})
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
                              -- for our own rid, we 
                              -- should get the data from SKV, 
                              -- not LSAs
                              self:a(lsa and usp)
                              self:a(rid ~= lsa.rid, 'own asp in iterate?')
                              f{prefix=usp.prefix, rid=lsa.rid}
                           end, {type=ospf_codec.AC_TLV_USP})
end

function elsa_pa:get_external_ifname_set()
   self:d('get_external_ifname_set')
   if not self.ext_set
   then
      local ext_set = mst.set:new{}
      -- determine the interfaces for which we don't want to provide
      -- interface callback (if we're using local interface-sourced
      -- delegated prefix, we don't want to offer anything there)
      self:iterate_skv_prefix(function (o)
                                 local ifname = o.ifname
                                 self:d('in use ifname', ifname)
                                 ext_set:insert(ifname)
                              end)
      self.ext_set = ext_set
   end
   return self.ext_set
end

function elsa_pa:add_seen_if(ifname)
   if self.all_seen_if_names[ifname]
   then
      return
   end
   self:d('added new interface to all_seen_if_names', ifname)
   self.all_seen_if_names:insert(ifname)

   -- invalidate caches that have if info
   self.skvp = nil
   self.ext_set = nil
end

--  iterate_if(rid, f) => callback with ifo
function elsa_pa:iterate_if(rid, f)
   self:d('called iterate_if')
   self.elsa:iterate_if(rid, function (ifo)
                           self:a(ifo)
                           self:add_seen_if(ifo.name)
                           local ext_set = self:get_external_ifname_set()
                           if ext_set[ifo.name]
                           then
                              ifo.external = true
                              --mst.d('marking ext')
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
   local skvp = self:get_skvp()
   for k, v in pairs(skvp)
   do
      f(v)
   end
end

function elsa_pa:get_skvp()
   if not self.skvp
   then
      -- temporary measure to find out invalid accesses + to enable us
      -- to check whether or not our state is still valid at the end
      -- too
      self.skvp = true
      local skvp = mst.map:new()
      self:iterate_all_skv_prefixes(function (p)
                                       self:a(p.prefix, 'no prefix object', p)
                                       skvp[p.prefix] = p
                                    end)
      -- if skvp is invalidated mid-calculation, re-calculate (this
      -- should not be eternal loop, as the invalidation happens if
      -- and only if we have skv state change (won't happen), or new
      -- interface added (happens limited number of times)
      if self.skvp ~= true
      then
         return self:get_skvp()
      end
      self.skvp = skvp
      self.skvp_repr = mst.repr(self.skvp)
   end
   return self.skvp, self.skvp_repr
end

function elsa_pa:iterate_all_skv_prefixes(f)
   local function create_metric_callback(metric)
      local function g(o, ifname)
         -- enter to the fallback lottery - the interface set we check
         -- should NOT decrease in size
         self:add_seen_if(ifname)
         
         -- old prefixes don't exist
         --if o.valid and o.valid < self.time()
         --then
         --   return
         --end

         -- may be non-prefix information too
         local p = o[PREFIX_KEY]
         if not p
         then
            return
         end
         local o2 = {prefix=p, ifname=ifname, nh=o[NH_KEY], metric=metric}
         -- copy over all other fields too, if applicable
         for _, k in ipairs(PREFIX_INFO_SKV_KEYS)
         do
            o2[k] = non_empty(o[k])
         end
         for _, k in ipairs(PREFIX_INFO_LOCAL_SKV_KEYS)
         do
            o2[k] = non_empty(o[k])
         end
         f(o2)
      end
      return g
   end
   self:iterate_skvprefix_o(PD_SKVPREFIX, create_metric_callback(1000))
   self:iterate_skvprefix_o(TUNNEL_SKVPREFIX, create_metric_callback(2000))
end

function elsa_pa:get_json_map(jsonfield, localo)
   local s = mst.map:new{}
   s[self.rid] = localo
   self:iterate_ac_lsa_tlv(function (json, lsa)
                              local o = json.table[jsonfield]
                              s[lsa.rid] = o
                           end, {type=ospf_codec.AC_TLV_JSONBLOB})
   self:d('get_json_map', jsonfield, s)
   return s
end

function elsa_pa:get_field_array(jsonfield, locala, cl, get_keys)
   local cl = cl or mst.set
   local s = cl:new{}
   local get_keys = get_keys or (cl == mst.set)
   
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
                           end, {type=ospf_codec.AC_TLV_JSONBLOB})


   if get_keys
   then
      -- return set as array

      -- obviously the order is arbitrary; however, without changes in
      -- the table, it won't change, so the no-change constraint can be
      -- still verified. in practise it would be nice to transmit across
      -- sub-table deltas instead of whole tables, but as long as we
      -- don't, this is good enough.
      s = s:keys()
   end
   return s
end


-- iterate callback called with object + name of interface (possibly N
-- times per interface name)
function elsa_pa:iterate_skvprefix_o(prefix, f)
   -- what we actually want to do per-ifname..
   local function g(ifname)
      local l = self.skv:get(string.format('%s%s', 
                                           prefix, ifname))
      if l
      then
         for i, o in ipairs(l)
         do
            f(o, ifname)
         end
      end
   end

   -- either use hardcoded list (if supplied via skv), or what's in
   -- all_seen_if_names.
   local hclist = self.skv:get(prefix .. IFLIST_KEY)
   if hclist
   then
      for i, ifname in ipairs(hclist)
      do
         g(ifname)
      end
   else
      for ifname, _ in pairs(self.all_seen_if_names)
      do
         g(ifname)
      end
   end
end

function elsa_pa:get_local_field_array(prefix, field, t)
   self:iterate_skvprefix_o(prefix,
                            function (o, ifname)
                               local v = non_empty(o[field])
                               -- don't forward empty strings - they can be created by 'stuff'
                               if not v
                               then
                                  return
                               end
                               t = t or mst.array:new{}
                               t:insert(v)
                            end)
   return t
end

function elsa_pa:get_local_asa_array()
   -- bit different than the rest, as this originates within pa code
   -- => what we do, is look at what's within the lap, and toss
   -- non-empty addresses
   local t = mst.array:new{}
   local laps = self.pa.lap:values():filter(function (lap) 
                                               return lap.ipv4 and lap.address 
                                            end)
   self:ph_list_sorted(laps)

   for i, lap in ipairs(laps)
   do
      t:insert({rid=self.rid, prefix=lap.address:get_ascii()})
   end
   return t
end

function elsa_pa:get_asa_array()
   return self:get_field_array(JSON_ASA_KEY, self:get_local_asa_array())
end

function elsa_pa:ph_list_sorted(l)
   local t = mst.table_copy(l or {})
   table.sort(t, function (o1, o2)
                 return o1.prefix:get_binary() < o2.prefix:get_binary()
                 end)
   return t
end

function elsa_pa:generate_ac_lsa(use_relative_timestamps)

   local _convert

   if use_relative_timestamps
   then
      -- convert to relative timestamps 
      local now = self.time()
      _convert = function (v)
         return absolute_to_relative(v, now)
      end
   else
      -- just use values as is (=absolute timestamps)
      _convert = function (v)
         return v
      end
   end

   -- adding these in deterministic order is mandatory; however, by
   -- default, the list ISN'T sorted in any sensible way.. so we have
   -- to do it
   self:d('generate_ac_lsa')

   local a = mst.array:new()

   -- generate RHF
   local hwf = self:get_padded_hwf(self.rid)
   self:d(' hwf', hwf)

   a:insert(ospf_codec.rhf_ac_tlv:encode{body=hwf})

   -- generate local USP-based TLVs

   --local uspl = self:ph_list_sorted(self.pa.usp[self.rid])
   local uspl = self.pa.usp[self.rid] or {}
   for i, usp in ipairs(uspl)
   do
      self:d(' usp', self.rid, usp.prefix)
      a:insert(ospf_codec.usp_ac_tlv:encode{prefix=usp.prefix})
   end

   -- generate (local) ASP-based TLVs
   --local aspl = self:ph_list_sorted(self.pa:get_local_asp_values())
   local aspl = self.pa:get_local_asp_values()
   for i, asp in ipairs(aspl)
   do
      self:d(' asp', self.rid, asp.iid, asp.prefix)
      a:insert(ospf_codec.asp_ac_tlv:encode{prefix=asp.prefix, iid=asp.iid})
   end

   -- generate 'FYI' blob out of local SKV state; right now, just the
   -- interface-specific DNS information, if any
   local t = mst.map:new{}

   for jsonkey, o in pairs(json_sources)
   do
      local l = self:get_local_field_array(o.prefix, o.key)
      t[jsonkey] = l
   end

   local l
   l = self:get_local_field_array(PD_SKVPREFIX, DNS_KEY, l)
   l = self:get_local_field_array(TUNNEL_SKVPREFIX, DNS_KEY, l)
   l = self:get_local_field_array(DHCPV4_SKVPREFIX, DNS_KEY, l)
   -- OSPF transport of DNS server is address family agnostic (can
   -- transfer either)
   if l
   then
      for i, v in ipairs(l)
      do
         self:d(' ds', v)
         a:insert(ospf_codec.ds_ac_tlv:encode{address=v})
      end
   end


   -- assigned IPv4 addresses
   t[JSON_ASA_KEY] = self:get_local_asa_array()

   -- router name (if any)
   if self.pa.rname
   then
      a:insert(ospf_codec.rn_ac_tlv:encode{name=self.pa.rname})
   end

   -- local domain preference (if any)
   local local_domain = self.skv:get(STATIC_HP_DOMAIN_KEY)
   if local_domain
   then
      -- if it's not in ll form, convert it
      local_domain = dns_db.name2ll(local_domain)
      a:insert(ospf_codec.dn_ac_tlv:encode{domain=local_domain})
      self:d(' dn', local_domain)
   end

   -- local zones (if any)
   local z1 = self.skv:get(STATIC_HP_ZONES_KEY)
   local z2 = self.skv:get(HP_MDNS_ZONES_KEY)
   local z = z1 or z2
   if z1 and z2
   then
      -- expensive; oh well
      z = mst.table_copy(z1)
      mst.array_extend(z, z2)
   end
   for i, o in ipairs(z or {})
   do
      -- convert to ll if not already
      local z = dns_db.name2ll(o.name)
      a:insert(ospf_codec.ddz_ac_tlv:encode{b=o.browse,
                                            s=o.search,
                                            zone=z,
                                            address=o.ip})
   end

   -- bonus USP prefix option list 
   local h
   self:iterate_skv_prefix(function (p)
                              -- may be non-prefixy thing in the
                              -- source, skip if so
                              if not p.prefix
                              then
                                 self:d(' .. ignoring, no prefix', p)
                                 return
                              end

                              -- ok, it really is prefix, let's see if
                              -- it has any extra usp info we might
                              -- want to propagate
                              local o = {}
                              for i, key in ipairs(PREFIX_INFO_SKV_KEYS)
                              do
                                 o[key] = non_empty(p[key])
                              end
                              -- in OSPF, we store relative timestamps;
                              -- so convert absolute timestamps to relative
                              o[VALID_KEY] = _convert(p[VALID_KEY])
                              o[PREFERRED_KEY] = _convert(p[PREFERRED_KEY])
                              if mst.table_count(o) > 0
                              then
                                 h = h or {}
                                 h[p.prefix] = o
                                 self:d(' .. gleaned', p.prefix, o)
                              else
                                 self:d(' .. nothing useful in', p)
                              end

                           end)
   if h
   then
      self:d('exporting usp info', h)
      t[JSON_USP_INFO_KEY] = h
   end

   if t:count() > 0
   then
      self:d(' json', t)
      a:insert(ospf_codec.json_ac_tlv:encode{table=t})
   end

   if #a
   then
      local s = table.concat(a)
      self:d('generated ac lsa of length', #s)
      return s
   end
end
