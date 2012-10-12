#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Oct  3 11:47:19 2012 mstenber
-- Last modified: Fri Oct 12 11:05:13 2012 mstenber
-- Edit time:     175 min
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

require 'mst'
require 'codec'
require 'ssloop'

local pa = require 'pa'

module(..., package.seeall)

AC_TYPE=0xBFF0

PD_IFLIST_KEY='pd-iflist'
PD_PREFIX_KEY='pd-prefix'

OSPF_LAP_KEY='ospf-lap'
OSPF_USP_KEY='ospf-usp'
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

elsa_lap = pa.lap:new_subclass{class='elsa_lap'}

function elsa_lap:start_depracate_timeout()
   local loop = ssloop.loop()
   self.timeout = loop:new_timeout_delta(LAP_DEPRACATE_TIMEOUT,
                                         function ()
                                            self.sm:Timeout()
                                         end)
   self.timeout:start()
end

function elsa_lap:stop_depracate_timeout()
   mst.a(self.timeout, 'stop_depracate_timeout without timeout?!?')
   self.timeout:stop()
end

function elsa_lap:start_expire_timeout()
   local loop = ssloop.loop()
   self.timeout = loop:new_timeout_delta(LAP_EXPIRE_TIMEOUT,
                                         function ()
                                            self.sm:Timeout()
                                         end)
   self.timeout:start()
end

function elsa_lap:stop_expire_timeout()
   mst.a(self.timeout, 'stop_depracate_timeout without timeout?!?')
   self.timeout:stop()
end



elsa_pa = mst.create_class{class='elsa_pa', mandatory={'skv', 'elsa'},
                          new_prefix_assignment=NEW_PREFIX_ASSIGNMENT,
                          new_ula_prefix=NEW_ULA_PREFIX}

function elsa_pa:init()
   self.first = true
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

   return true
end

function elsa_pa:run()
   self:d('run starting')

   -- let's check first that there is no conflict; that is,
   -- nobody else with different hw fingerprint, but same rid
   --
   -- if someone like that exists, either we (or they) have to change
   -- their router id..
   if self:check_conflict() then return end

   -- our rid may have changed -> change that of the pa too, just in case
   self.pa.rid = self.rid

   local r = self.pa:run()

   self:d('pa.run result', r, self.first)
   if r or self.first
   then

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
         t:insert({ifname=lap.ifname, prefix=lap.prefix,
                   depracate=lap.depracated and 1 or 0})
      end
      self.skv:set(OSPF_LAP_KEY, t)

      -- set up the interface list
      local t = mst.array:new{}
      for iid, ifo in pairs(self.pa.ifs)
      do
         t:insert(ifo.name)
      end
      self.skv:set(OSPF_IFLIST_KEY, t)

      -- toss in the usp's too
      local t = mst.array:new{}
      local dumped = mst.set:new{}

      self:d('creating usp list')

      for i, v in ipairs(self.pa.usp:values())
      do
         local p = v.prefix
         if not dumped[p]
         then
            self:d('got from pa.usp', p)
            dumped:insert(p)
            t:insert({prefix=p})
         end
      end

      -- toss also usp's from the LAP, which still live
      for i, lap in ipairs(self.pa.lap:values())
      do
         local p = lap.asp.usp.prefix
         if not dumped[p]
         then
            self:d('got from pa.lap', p)
            dumped:insert(p)
            t:insert({prefix=p})
         end
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
   self.elsa:iterate_lsa(f, criteria)
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
   -- we're always reachable (duh)
   f(rid)

   -- the rest, we look at LSADB 
   self:iterate_ac_lsa(function (lsa) f(lsa.rid) end)
end

--  iterate_asp(rid, f) => callback with prefix, iid, rid
function elsa_pa:iterate_asp(rid, f)
   self:iterate_ac_lsa_tlv(function (asp, lsa) 
                              self:a(lsa and asp)
                              f(asp.prefix, asp.iid, lsa.rid)
                           end, {type=codec.AC_TLV_ASP})
end

--  iterate_usp(rid, f) => callback with prefix, rid
function elsa_pa:iterate_usp(rid, f)
   self:iterate_skv_prefix(function (prefix)
                              f(prefix, rid)
                           end)
   self:iterate_ac_lsa_tlv(function (usp, lsa)
                              self:a(lsa and usp)
                              f(usp.prefix, lsa.rid)
                           end, {type=codec.AC_TLV_USP})
end

--  iterate_if(rid, f) => callback with ifo, highest_rid
function elsa_pa:iterate_if(rid, f)
   local inuse_ifnames = mst.set:new{}

   -- determine the interfaces for which we don't want to provide
   -- interface callback (if we're using local interface-sourced
   -- delegated prefix, we don't want to offer anything there)
   self:iterate_skv_prefix(function (prefix, ifname)
                              mst.d('in use ifname', ifname)
                              inuse_ifnames:insert(ifname)
                           end)

   self.elsa:iterate_if(rid, function (ifo, highest_rid)
                           self.all_seen_if_names:insert(ifo.name)
                           self:a(ifo)
                           if not inuse_ifnames[ifo.name]
                           then
                              f(ifo, highest_rid)
                           else
                              mst.d('skipping in use', ifo, 'delegated prefix source')
                           end
                        end)
end

function elsa_pa:iterate_skv_prefix(f)
   local pdlist = self.skv:get(PD_IFLIST_KEY)
   for i, ifname in ipairs(pdlist or self.all_seen_if_names:keys())
   do
      if pdlist
      then
         -- enter to the fallback lottery - the stuff returned by this
         -- should NOT decrease in size
         self.all_seen_if_names:insert(ifname)
      end

      local o = self.skv:get(string.format('pd-prefix.%s', ifname) )
      if o
      then
         local prefix, valid
         if type(o) == 'string'
         then
            prefix = o
            valid = nil
         else
            prefix, valid = unpack(o)
         end
         if not valid or valid >= os.time()
         then
            f(prefix, ifname)
         end
      end
   end
end

function elsa_pa:generate_ac_lsa()
   local a = mst.array:new()

   -- generate RHF
   local hwf = self:get_padded_hwf(self.rid)
   a:insert(codec.rhf_ac_tlv:encode{body=hwf})

   -- generate local USP-based TLVs
   self:iterate_skv_prefix(function (prefix)
                              a:insert(codec.usp_ac_tlv:encode{prefix=prefix})
                           end)

   -- generate (local) ASP-based TLVs
   for i, asp in ipairs(self.pa:get_local_asp_values())
   do
      a:insert(codec.asp_ac_tlv:encode{prefix=asp.prefix, iid=asp.iid})
   end
   if #a
   then
      return table.concat(a)
   end
end
