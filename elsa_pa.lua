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
-- Last modified: Thu Oct  4 19:34:45 2012 mstenber
-- Edit time:     80 min
--

-- the main logic around with prefix assignment within e.g. BIRD works
-- 
-- elsa_pa is given skv instance, elsa instance, and should roll on
-- it's way. 

AC_TYPE=0xBFF0

PD_IFLIST_KEY='pd-iflist'
PD_PREFIX_KEY='pd-prefix'

OSPF_LAP_KEY='ospf-lap'
OSPF_USP_KEY='ospf-usp'
OSPF_IFLIST_KEY='ospf-iflist'

-- #define LSA_T_AC        0xBFF0 /* Auto-Configuration LSA */
--  /* function code 8176(0x1FF0): experimental, U-bit=1, Area Scope */

require 'mst'
require 'codec'

local pa = require 'pa'

module(..., package.seeall)

elsa_pa = mst.create_class{class='elsa_pa', mandatory={'skv', 'elsa'}}

function elsa_pa:init()
   local rid = self.rid
   self.first = true
   self.pa = pa.pa:new{rid=rid, client=self}
end

function elsa_pa:uninit()
   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state

   self.pa:done()
end

function elsa_pa:run()
   local r = self.pa:run()
   if r or self.first
   then
      -- originate LSA (or try to, there's duplicate prevention, or should be)
      self.elsa:originate_lsa{type=AC_TYPE, 
                              rid=self.pa.rid,
                              body=self:generate_ac_lsa()}

      -- set up the locally assigned prefix field
      local t = mst.array:new()
      for i, lap in ipairs(self.pa.lap:values())
      do
         local ifname = self.pa.ifs[lap.iid]
         if ifname
         then
            t:insert({ifname=ifname.name, prefix=lap.prefix})
         else
            self:d('zombie interface', lap)
         end
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
      for i, v in ipairs(self.pa.usp:values())
      do
         t:insert({prefix=v.prefix})
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

--  iterate_if(rid, f) => callback with iid, highest_rid
function elsa_pa:iterate_if(rid, f)
   self.elsa:iterate_if(rid, function (iid, highest_rid)
                           self:a(iid)
                           f(iid, highest_rid)
                        end)
end

function elsa_pa:iterate_skv_prefix(f)
   for i, ifname in ipairs(self.skv:get(PD_IFLIST_KEY) or 
                           self.skv:get(OSPF_IFLIST_KEY) or 
                           {})
   do
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
            f(prefix)
         end
      end
   end
end

function elsa_pa:generate_ac_lsa()
   local a = mst.array:new()

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
