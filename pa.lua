#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  1 11:08:04 2012 mstenber
-- Last modified: Tue Oct  9 15:03:48 2012 mstenber
-- Edit time:     371 min
--

-- This is homenet prefix assignment algorithm, written using fairly
-- abstract data structures. The network abstraction object should
-- provide a way of doing the required operations, and should call us
-- whenever it's state changes.

-- client expected to provide:
--  iterate_rid(rid, f) => callback with rid
--  iterate_asp(rid, f) => callback with prefix, iid, rid
--  iterate_usp(rid, f) => callback with prefix, rid
--  iterate_if(rid, f) => callback with if-object, highest_rid
--  rid (or given to constructor)

-- client can also override/subclass the lap class here within pa, to
-- provide the real assign/unassign/deprecation (by providing do_*
-- methods). once done, they should call Done/Error. if asynchronous,
-- they should also provide stop_* methods.

require 'mst'
require 'ipv6s'
local md5 = require 'md5'

-- SMC-generated state machine
-- fix braindeath of using pcall in a state machine in general..
-- and not returning errors in particular
local orig_pcall = pcall
function pcall(f)
   -- errors, huh?
   f()
end
local lap_sm = require 'pa_lap_sm'
pcall = orig_pcall


--mst.enable_debug = true

module('pa', package.seeall)

-- local assigned prefix

lap = mst.create_class{class='lap', mandatory={'prefix', 'iid', 'pa'}}

function lap:init()
   local ifo = self.pa.ifs[self.iid]
   mst.a(ifo, 'non-existent interface iid', self.iid)
   self.ifname = ifo.name
   self.pa.lap:insert(self.iid, self)
   self.sm = lap_sm:new{owner=self}
   self.sm:enterStartState()
   self:assign()
   self.pa:changed()
end

function lap:uninit()
   self:d('uninit')
   self:depracate()
   self.pa.lap:remove(self.iid, self)
   self.pa:changed()
end

function lap:repr_data()
   return mst.repr{prefix=self.prefix, iid=self.iid}
end

function lap:start_depracate_timeout()
   -- child responsibility - should someday result in a Timeout()
end

function lap:stop_depracate_timeout()

end

function lap:start_expire_timeout()
   -- child responsibility - should someday result in a Timeout()
end

function lap:stop_expire_timeout()

end

function lap:error(s)
   self:d('got error', s)
end

-- external API (which is just forwarded to the state machine)

function lap:assign()
   self.sm:Assign()
end

function lap:unassign()
   self.sm:Unassign()
end

function lap:depracate()
   self.sm:Depracate()
end

-- these are subclass responsibility (optionally - it can also just
-- use the assigned/depracated flags these set)
function lap:do_assign()
   mst.a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = true
   self.depracated = false
   self.sm:Done()
end

function lap:do_depracate()
   mst.a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = false
   self.depracated = true
   self.sm:Done()
end

function lap:do_unassign()
   mst.a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = false
   self.sm:Done()
end

-- assigned prefix

asp = mst.create_class{class='asp', mandatory={'prefix', 
                                               'iid', 
                                               'rid', 
                                               'pa'}}

function asp:init()
   local added = self.pa.asp:insert(self.rid, self)
   mst.a(added, "already existed?", self)
   self:d('init')
   self.pa:changed()
end

function asp:uninit()
   self:d('uninit')

   -- unassign is better - it has some built-in tolerance
   -- (depracate = instantly offline)
   self:unassign_lap()

   self.pa.asp:remove(self.rid, self)
   self.pa:changed()
end

function asp:repr_data()
   return mst.repr{prefix=self.prefix, iid=self.iid, rid=self.rid}
end

function asp:find_lap()
   self:d('find_lap')
   mst.a(self.class)
   mst.a(self.pa, 'no pa?!?')
   local t = self.pa.lap[self.iid]
   for i, v in ipairs(t or {})
   do
      self:d(' considering', v)
      if v.prefix == self.prefix
      then
         -- update the asp object, just in case..
         v.asp = self
         return v
      end
   end
end

function asp:find_or_create_lap()
   self:d('find_or_create_lap')
   local o = self:find_lap()
   if o then return o end
   self:d(' not found => creating')

   -- mark that something changed so pa knows it too
   -- (some branches of the logic, e.g. assign_other, won't, otherwise)
   self.pa:changed()

   return self.pa.lap_class:new{prefix=self.prefix, iid=self.iid, 
                                asp=self,
                                pa=self.pa}
end

function asp:assign_lap()
   mst.a(self.class == 'asp')
   local lap = self:find_or_create_lap()
   lap:assign()
end

function asp:depracate_lap()
   -- look up locally assigned prefixes (if any)
   local lap = self:find_lap()
   if not lap then return end
   lap:depracate()
end

function asp:unassign_lap()
   -- look up locally assigned prefixes (if any)
   local lap = self:find_lap()
   if not lap then return end
   lap:unassign()
end

function asp:is_remote()
   return self.rid ~= self.pa.rid
end

-- usable prefix, can be either local or remote (no behavioral
-- difference though?)
usp = mst.create_class{class='usp', mandatory={'prefix', 'rid', 'pa'}}

function usp:init()
   local added = self.pa.usp:insert(self.rid, self)
   mst.a(added, 'already existed?', self)
   self.pa:changed()
end

function usp:uninit()
   self:d('uninit')
   self.pa.usp:remove(self.rid, self)
   self.pa:changed()
end

function usp:repr_data()
   return mst.repr{prefix=self.prefix, rid=self.rid}
end

pa = mst.create_class{class='pa', lap_class=lap, mandatory={'rid'}}

-- main prefix assignment class

function pa:init()
   -- locally assigned prefixes - iid => list
   self.lap = mst.multimap:new()

   -- rid reachability => true/false (reachable right now)
   self.ridr = mst.map:new()

   -- all asp data, ordered by prefix
   self.asp = mst.multimap:new()

   -- all usp data, ordered by prefix
   self.usp = mst.multimap:new()

   -- init changes to 0 here (it's cleared at _end_ of each pa:run,
   -- but timeouts may cause it to become non-zero before next pa:run)
   self.changes = 0
end

function pa:uninit()
   self:d('uninit')

   -- just kill the contents of all datastructures
   self:filtered_values_done(self.usp)
   self:filtered_values_done(self.asp)
   self:filtered_values_done(self.lap)
end

function pa:filtered_values_done(h, f)
   mst.a(h.class == 'multimap')
   for i, o in ipairs(h:values())
   do
      if f and f(o) 
      then 
         self:d('done with', o)
         o:done() 
      end
   end
end

function pa:get_local_asp_values()
   mst.a(self)
   mst.a(self.class=='pa')

   return self.asp:values():filter(function (v) return not v:is_remote() end)
end

function pa:repr_data()
   if not self.asp
   then
      return '?'
   end
   local asps = self.asp:values()
   local lasp = self:get_local_asp_values()

   return string.format('rid:%s #lap:%d #ridr:%d #asp:%d[%d] #usp:%d #if:%d',
                        self.rid,
                        #self.lap:values(),
                        #self.ridr:values(),
                        #asps, 
                        #lasp, 
                        #self.usp:values(),
                        self.ifs and #self.ifs:values() or -1)
end

function pa:run_if_usp(iid, highest_rid, usp)
   local rid = self.rid

   self:a(rid, 'no rid')


   self:d('run_if_usp', iid, usp.prefix)


   -- Alg from 6.3.. steps noted 
   
   -- 1. if some shorter prefix contains this usp, skip
   for i, v in ipairs(self.usp:values())
   do
      -- XXX - complain that this seems broken
      -- (BCP38 stuff might make it not-so-working?)
      if v.prefix ~= usp.prefix and ipv6s.prefix_contains(v.prefix, usp.prefix)
      then
         self:d('skipped, containing prefix found')
         return
      end
   end

   -- (skip 2. - we don't really care about neighbors)

   -- 3. determine highest rid of already assigned prefix on the link
   local own
   local highest
   
   for i, asp in ipairs(self.asp:values())
   do
      self:d(' considering', asp)
      if asp.iid == iid and ipv6s.prefix_contains(usp.prefix, asp.prefix)
      then
         self:d(' fitting')
         if not highest or highest.rid < asp.rid
         then
            highest = asp
         end
         if asp.rid == rid
         then
            own = asp
         end
      end
   end

   -- 4.
   -- (i) - router made assignment, highest router id
   if own and own == highest
   then
      own.usp = usp
      self:check_asp_conflicts(own)
      return
   end
   -- (ii) - assignment by neighbor
   if highest
   then
      highest.usp = usp
      self:assign_other(highest)
      return
   end

   -- (iii) no assignment by anyone, highest rid
   if not highest_rid or highest_rid <= rid 
   then
      self:assign_own(iid, usp)
      return
   end

   -- (iv) no assignment by anyone, not highest rid
   -- nop (do nothing)
end

-- 6.3.1
function pa:assign_own(iid, usp)
   self:d('6.3.1 assign_own', iid, usp)

   -- 1. find already assigned prefixes
   assigned = self:find_assigned(usp)

   -- 2. try to find 'old one'
   local p
   for i, v in ipairs(self.lap:values())
   do
      if v.iid == iid and v.deprecated and ipv6s.prefix_contains(usp.prefix, v.prefix)
      then
         if not assigned[v.prefix]
         then
            p = v.prefix
         end
      end
   end

   if not p
   then
      local old = self:get_old_assignments()
      if old
      then
         self:d('considering old assignments', usp.prefix)

         for i, v in ipairs(old[usp.prefix] or {})
         do
            --self:d('got', v)
            local oiid, oprefix = unpack(v)
            self:d('  ', oiid, oprefix)

            if oiid == iid 
            then
               if not assigned[oprefix]
               then
                  self:d(' found in old assignments', oprefix)
                  p = oprefix
               else
                  self:d(' found in old assignments, but reserved', oprefix)
               end
            end
         end
      end
   end

   -- XXX - could also get from e.g. storage

   -- 3. assign /64 if possible
   if not p
   then
      p = self:find_new_from(iid, usp, assigned)
   end
   
   -- 4. hysteresis (sigh)
   -- XXX
   
   -- 5. if none available, skip
   if not p
   then
      return
   end

   -- 6. if assigned, mark as valid + send AC LSA
   local o = asp:new{prefix=p,
                     usp=usp,
                     pa=self,
                     iid=iid,
                     rid=self.rid, 
                     valid=true}
   o:assign_lap()
end

-- child responsibility - return old assignment multimap, with
-- usp-prefix => {{iid, asp-prefix}, ...}
function pa:get_old_assignments()
   return self.old_assignments
end

function pa:find_assigned(usp)
   local t = mst.set:new()
   for i, asp in ipairs(self.asp:values())
   do
      if ipv6s.prefix_contains(usp.prefix, asp.prefix)
      then
         local b = ipv6s.prefix_to_bin(asp.prefix)
         t:insert(b)
         mst.a(#b == 8, "invalid asp length", #b)
      end
   end
   return t
end

function pa:find_new_from(iid, usp, assigned)
   local b = ipv6s.prefix_to_bin(usp.prefix)
   local p
   local ipv6prefix_suffix = '::/64'
   self:a(assigned, 'assigned missing')
   mst.a(b)

   -- initially, try 10 times (completely arbiterary number) to figure
   -- a randomish prefix (based on the router id)
   for i=1,10
   do
      -- get the rest of the bytes from md5
      local s = string.format("%s-%s-%s-%d", self.rid, iid, usp.prefix, i)
      local sb = md5.sum(s)
      p = b .. string.sub(sb, #b+1, 8)
      mst.a(#p == 8)
      if not assigned[p]
      then
         return ipv6s.binary_to_ascii(p) .. ipv6prefix_suffix
      end
   end

   -- use the last prefix as base, iterate through the whole usable prefix
   local sp = p
   while true
   do
      p = binary_prefix_next_from_usp(b, p)
      mst.a(#p == 8, "binary_prefix_next_from_usp bugs?")

      if not assigned[p]
      then
         return ipv6s.binary_to_ascii(p) .. ipv6prefix_suffix
      end

      -- prefix is full if we're back at start
      if sp == b
      then
         return
      end
   end
end

-- 6.3.2
function pa:check_asp_conflicts(asp)
   self:d('6.3.2 check_asp_conflicts', asp)
   for i, asp2 in ipairs(self.asp:values())
   do
      -- if conflict, with overriding rid is found, depracate prefix
      if asp2.prefix == asp.prefix and asp2.rid > asp.rid
      then
         -- as described in 6.3.3
         asp:depracate()
         return
      end
   end
   -- otherise mark it as valid
   asp.valid = true
end

-- 6.3.4
function pa:assign_other(asp)
   self:d('6.3.4 assign_other', asp)
   -- if we get here, it's valid asp.. just question of what we need
   -- to do with lap
   asp.valid = true

   -- So we just fire up the assign_lap, it will ignore duplicate calls anyway

   -- Note: the verbiage about locally converted interfaces etc seems
   -- excessively strict in the draft.
   asp:assign_lap()
end

function pa:run()
   self:d('run called')

   local client = self.client
   local rid = self.rid

   mst.a(client, 'no client')

   -- store the index => if-object (and less material index => highest-rid)
   self.ifs = mst.map:new()
   self.highest = mst.map:new()

   client:iterate_if(rid, function (ifo, highest_rid)
                        self:d('got if', ifo)
                        self.ifs[ifo.index] = ifo
                        self.highest[ifo.index] = highest_rid
                     end
                    )


   -- mark existing data invalid
   -- (laps have their own lifecycle governed via timeouts etc)
   self.asp:foreach(function (ii, o) o.valid = false end)
   self.usp:foreach(function (ii, o) o.valid = false end)
   self.ridr:keys():map(function (k) self.ridr[k]=false end)

   -- get the rid reachability
   client:iterate_rid(rid, function (rid)
                         self:d('got rid', rid)
                         self.ridr[rid] = true
                      end)

   -- get the usable prefixes from the 'client' [prefix => rid]
   client:iterate_usp(rid, function (prefix, rid)
                         self:d('got usp', prefix, rid)
                         self:add_or_update_usp(prefix, rid)
                      end)

   -- drop those that are not valid immediately
   self:filtered_values_done(self.usp,
                             function (usp) return not usp.valid end)
   
   -- get the (remotely) assigned prefixes
   client:iterate_asp(rid, function (prefix, iid, rid)
                         self:d('got asp', prefix, iid, rid)
                         self:add_or_update_asp(prefix, iid, rid)
                      end)

   -- drop expired remote assignments
   self:filtered_values_done(self.asp,
                             function (asp) 
                                mst.a(asp.class == 'asp', asp, asp.class)
                                return asp:is_remote() and not asp.valid 
                             end)

   -- run the prefix assignment
   for iid, ifo in pairs(self.ifs)
   do
      local highest_rid = self.highest[iid]
      for i, usp in ipairs(self.usp:values())
      do
         mst.a(usp.class == 'usp', usp, usp.class)
         self:run_if_usp(iid, highest_rid, usp)
      end
   end

   -- handle the expired local assignments
   for i, asp in ipairs(self:get_local_asp_values())
   do
      if not asp.valid
      then
         asp:done()
      end
   end

   self:d('run done', self.changes)

   if self.changes > 0
   then
      local r = self.changes
      self.changes = 0
      return r
   end
end

function pa:add_or_update_usp(prefix, rid)
   self:a(self.ridr[rid], 'sanity-check failed - rid not reachable', rid)
   for i, o in ipairs(self.usp[rid] or {})
   do
      if o.prefix == prefix
      then
         self:d(' updated old usp')
         o.valid = true
         return
      end
   end
   self:d(' adding new usp')
   usp:new{prefix=prefix, rid=rid, pa=self, valid=true}
end

function pa:get_asp(prefix, iid, rid)
   for i, o in ipairs(self.asp[rid] or {})
   do
      if o.prefix == prefix and o.iid == iid
      -- and o.rid == rid (implicit from the hash by rid)
      then
         return o
      end
   end
end

function pa:add_or_update_asp(prefix, iid, rid)
   self:a(self.ridr[rid], 'sanity-check failed - rid not reachable', rid)
   local o = self:get_asp(prefix, iid, rid)
   if o
   then
      self:d(' updated old asp', o:is_remote())
      -- mark it valid if it's remote
      if o:is_remote()
      then
         o.valid = true
      else
         self:a(o.rid == self.rid, o.rid, self.rid)

         -- validity should be governed by PA alg
         self:a(not o.valid)
      end
      return
   elseif rid == self.rid
   then
      self:d(' skipping own asp (delete?)')
      return
   end
   self:d(' adding new asp')
   asp:new{prefix=prefix, iid=iid, rid=rid, pa=self, valid=true}
   self.changes = self.changes + 1
end

function pa:changed()
   self.changes = self.changes + 1
end
