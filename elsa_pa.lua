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
-- Last modified: Thu Oct  4 12:34:51 2012 mstenber
-- Edit time:     53 min
--

-- the main logic around with prefix assignment within e.g. BIRD works
-- 
-- elsa_pa is given skv instance, elsa instance, and should roll on
-- it's way. 

AC_TYPE=0x1234

require 'mst'
require 'codec'

local pa = require 'pa'

module(..., package.seeall)

elsa_pa = mst.create_class{class='elsa_pa', mandatory={'skv', 'elsa'}}

function elsa_pa:init()
   local rid = self.rid
   self.pa = pa.pa:new{rid=rid, client=self}
end

function elsa_pa:uninit()
   -- we don't 'own' skv or 'elsa', so we don't do anything here,
   -- except clean up our own state

   self.pa:done()
end

function elsa_pa:run()
   local r = self.pa:run()
   if r
   then
      self.elsa:originate_lsa{type=AC_TYPE, 
                              rid=self.pa.rid,
                              body=self:generate_ac_lsa()}
      local t = mst.set:new()
      for i, lap in ipairs(self.pa.lap:values())
      do
         -- XXX - map iid => ifname
         t:insert({ifname=lap.iid, prefix=lap.prefix})
      end
      self.skv:set('ospf-lap', t)
   end
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

--  iterate_rid(f) => callback with rid
function elsa_pa:iterate_rid(f)
   self:iterate_ac_lsa(function (lsa) f(lsa.rid) end)
end

--  iterate_asp(f) => callback with prefix, iid, rid
function elsa_pa:iterate_asp(f)
   self:iterate_ac_lsa_tlv(function (asp, lsa) 
                              self:a(lsa and asp)
                              f(asp.prefix, asp.iid, lsa.rid)
                           end, {type=codec.AC_TLV_ASP})
end

--  iterate_usp(f) => callback with prefix, rid
function elsa_pa:iterate_usp(f)
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

function elsa_pa:generate_ac_lsa()
   local a = mst.array:new()

   -- generate USP-based TLVs
   for i, ifname in ipairs(self.skv:get('iflist') or {})
   do
      local o = self.skv:get(string.format('pd.%s', ifname) )
      if o
      then
         local prefix, valid = unpack(o)
         if not valid or valid >= os.time()
         then
            a:insert(codec.usp_ac_tlv:encode{prefix=prefix})
         end
      end
   end

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
