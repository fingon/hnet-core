#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pa.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct  1 11:08:04 2012 mstenber
-- Last modified: Fri Oct 26 22:02:02 2012 mstenber
-- Edit time:     615 min
--

-- This is homenet prefix assignment algorithm, written using fairly
-- abstract data structures. The network abstraction object should
-- provide a way of doing the required operations, and should call us
-- whenever it's state changes.

-- client expected to provide:
--  get_hwf(rid) => hardware fingerprint in string
--  iterate_rid(rid, f) => callback with {rid=[, ifname=, nh=]}
--  iterate_asp(rid, f) => callback with {prefix=, iid=, rid=}
--  iterate_usp(rid, f) => callback with {prefix=, rid=}
--  iterate_if(rid, f) => callback with if-object
--   iterate_ifo_neigh(rid, if-object, f) => callback with {iid=, rid=}
--  .rid (or given to constructor)

-- client can also override/subclass the lap class here within pa, to
-- provide the real assign/unassign/deprecation (by providing do_*
-- methods). once done, they should call Done/Error. if asynchronous,
-- they should also provide stop_* methods.

require 'mst'
require 'ipv6s'

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

module('pa', package.seeall)

-- wrapper we can override
create_hash=nil
create_hash_type=nil

pcall(function ()
         local md5 = require 'md5'
         create_hash=md5.sum
         create_hash_type='md5'
      end)

if not create_hash
then
   print('using sha1')
   require 'sha1'
   create_hash = sha1_binary
   create_hash_type='sha1'
   print('using sha1')
end

-- sanity checking
function _valid_rid(s)
   -- we use strings internally for test purposes
   return type(s) == 'string' or type(s) == 'number'
end

function _valid_iid(s)
   return type(s) == 'number'
end

function _valid_local_iid(pa, s)
   mst.a(pa and s)
   return pa.ifs[s]
end

-- prefix handler base (used in lap, asp, usp)
ph = mst.create_class{class='ph'}

function ph:init()
   self:a(self.prefix)
   if type(self.prefix) == 'string' 
   then 
      self.prefix=ipv6s.new_prefix_from_ascii(self.prefix)
   end

   self.ascii_prefix = self.prefix:get_ascii()
   self.binary_prefix = self.prefix:get_binary()
end

-- local assigned prefix

lap = ph:new_subclass{class='lap', mandatory={'prefix', 'iid', 'pa'},
                      assigned=false,
                      depracated=false}

function lap:init()
   -- superclass init
   ph.init(self)

   local ifo = self.pa.ifs[self.iid]
   self:a(ifo, 'non-existent interface iid', self.iid)
   self.ifname = ifo.name
   self.pa.lap:insert(self.iid, self)
   self.sm = lap_sm:new{owner=self}
   self.sm.debugFlag = true
   self.sm.debugStream = {write=function (f, s)
                             self:d(mst.string_strip(s))
                                end}
   self.sm:enterStartState()
   self:assign()
   self.pa:changed()
end

function lap:uninit()
   self:d('uninit')

   -- get rid of timeouts, if any
   self.sm:UnInit()

   -- remove from parent, mark that parent changed
   self.pa.lap:remove(self.iid, self)
   self.pa:changed()
end

function lap:repr_data()
   return mst.repr{prefix=self.ascii_prefix, 
                   iid=self.iid, 
                   za=self.assigned,
                   zd=self.depracated,
                  }
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
   if not self.assigned
   then
      -- depracate immediately any other prefix that is on this iid,
      -- with same USP as us (self->asp->usp.prefix)
      local usp = self.asp.usp
      for i, lap2 in ipairs(self.pa.ifs[self.iid])
      do
         if lap ~= lap2 and usp.prefix:contains(lap2.prefix)
         then
            lap2:depracate()
         end
      end
   end
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
   self:a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = true
   self.depracated = false
   self.sm:Done()
end

function lap:do_depracate()
   self:a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = false
   self.depracated = true
   self.sm:Done()
end

function lap:do_unassign()
   self:a(not self._is_done, 'called when done')
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
   -- superclass init
   ph.init(self)

   local added = self.pa.asp:insert(self.rid, self)
   self:a(added, "already existed?", self)

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
   return mst.repr{prefix=self.ascii_prefix, iid=self.iid, rid=self.rid}
end

function asp:find_lap(iid)
   self:d('find_lap')
   self:a(_valid_local_iid(self.pa, iid))
   self:a(self.class)
   self:a(self.pa, 'no pa?!?')
   local t = self.pa.lap[iid]
   for i, v in ipairs(t or {})
   do
      self:d(' considering', v)
      if v.ascii_prefix == self.ascii_prefix
      then
         -- update the asp object, just in case..
         v.asp = self
         return v
      end
   end
end

function asp:find_or_create_lap(iid)
   self:d('find_or_create_lap')
   self:a(_valid_local_iid(self.pa, iid))
   local o = self:find_lap(iid)
   if o then return o end
   self:d(' not found => creating')

   -- mark that something changed so pa knows it too
   -- (some branches of the logic, e.g. assign_other, won't, otherwise)
   self.pa:changed()

   return self.pa.lap_class:new{prefix=self.prefix, 
                                iid=iid,
                                asp=self,
                                pa=self.pa}
end

function asp:assign_lap(iid)
   self:a(_valid_local_iid(self.pa, iid))
   self:a(self.class == 'asp')
   local lap = self:find_or_create_lap(iid)
   lap:assign()
   lap.owner = self.rid == self.pa.rid and true or nil
end

function asp:depracate_lap(iid)
   -- look up locally assigned prefixes (if any)
   local lap = self:find_lap(iid)
   if not lap then return end
   lap:depracate()
end

function asp:unassign_lap(iid)
   -- look up locally assigned prefixes (if any)
   -- brute-force through the lap - if prefix is same, we're good
   for _, lap in ipairs(self.pa.lap:values())
   do
      if lap.ascii_prefix == self.ascii_prefix
      then
         lap:unassign()
         return
      end
   end
end

function asp:is_remote()
   return self.rid ~= self.pa.rid
end

-- usable prefix, can be either local or remote (no behavioral
-- difference though?)
usp = mst.create_class{class='usp', mandatory={'prefix', 'rid', 'pa'}}

function usp:init()
   -- superclass init
   ph.init(self)

   local added = self.pa.usp:insert(self.rid, self)
   self:a(added, 'already existed?', self)

   self.pa:changed()
end

function usp:uninit()
   self:d('uninit')
   self.pa.usp:remove(self.rid, self)
   self.pa:changed()
end

function usp:repr_data()
   return mst.repr{prefix=self.ascii_prefix, rid=self.rid}
end


function usp:get_random_binary_prefix(iid, i)
   local b = self.binary_prefix
   i = i or 0
   -- get the rest of the bytes from md5
   local s = string.format("%s-%s-%s-%d", 
                           self.pa.rid, iid, self.ascii_prefix, i)
   local sb = create_hash(s)
   p = b .. string.sub(sb, #b+1, 8)
   self:a(#p == 8)
   return p
end

function usp:create_prefix_freelist(assigned)
   if self.freelist then return self.freelist end

   local b = self.binary_prefix
   local t = mst.array:new()

   self.freelist = t

   if #b >= 8
   then
      return t
   end

   -- use the last prefix as base, iterate through the whole usable prefix
   local p = b .. string.rep(string.char(0), 8-#b)
   local sp = p
   while true
   do
      p = ipv6s.binary_prefix_next_from_usp(b, p)
      self:a(#p == 8, "binary_prefix_next_from_usp bugs?")

      if not assigned[p]
      then
         local np = ipv6s.new_prefix_from_binary(p)
         self:a(self.prefix:contains(np))
         t:insert(np)
      end

      -- we're done once we're back at start
      if sp == p
      then
         self:d('created freelist', #t)
         return t
      end
   end
   -- never reached
end

-- main prefix assignment class


pa = mst.create_class{class='pa', lap_class=lap, mandatory={'rid'},
                      new_prefix_assignment=0,
                      new_ula_prefix=0,
                      random_prefix_tries=5}

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

   -- store when we started, for hysteresis calculations
   self.start_time = os.time()
end

function pa:uninit()
   self:d('uninit')

   -- just kill the contents of all datastructures
   self:filtered_values_done(self.lap)
   self:filtered_values_done(self.asp)
   self:filtered_values_done(self.usp)
end

function pa:filtered_values_done(h, f)
   self:a(h.class == 'multimap')
   for i, o in ipairs(h:values())
   do
      if not f or f(o) 
      then 
         self:d('done with', o)
         o:done() 
      end
   end
end

function pa:get_local_asp_values()
   self:a(self)
   self:a(self.class=='pa')

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

function pa:run_if_usp(iid, neigh, usp)
   local rid = self.rid
   self:a(_valid_rid(rid))

   self:a(rid, 'no rid')


   self:d('run_if_usp', iid, usp.prefix, neigh)


   -- Alg from 6.3.. steps noted 
   
   -- 1. if some shorter prefix contains this usp, skip
   for i, v in ipairs(self.usp:values())
   do
      -- XXX - complain that this seems broken
      -- (BCP38 stuff might make it not-so-working?)
      if v.ascii_prefix ~= usp.ascii_prefix and v.prefix:contains(usp.prefix)
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
      if ((asp.rid == rid and iid == asp.iid) or neigh[asp.rid] == asp.iid) and usp.prefix:contains(asp.prefix)
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
      self:check_asp_conflicts(iid, own)
      return
   end
   -- (ii) - assignment by neighbor
   if highest
   then
      highest.usp = usp
      self:assign_other(iid, highest)
      return
   end

   -- (iii) no assignment by anyone, highest rid?
   -- XXX - should we check for AC-enabled neighbors here only?
   local neigh_rids = neigh:keys()
   local highest_rid = mst.max(unpack(neigh_rids))
   self:a(not highest_rid or _valid_rid(highest_rid), 'invalid highest_rid', highest_rid)
   if not highest_rid or highest_rid <= rid 
   then
      self:assign_own(iid, usp)
      return
   end

   -- (iv) no assignment by anyone, not highest rid
   -- nop (do nothing)
   self:d('no assignments, lower rid than', highest_rid)
end

-- 6.3.1
function pa:assign_own(iid, usp)
   self:d('6.3.1 assign_own', iid, usp)
   self:a(_valid_local_iid(self, iid))

   -- 1. find already assigned prefixes
   assigned = self:find_assigned(usp)

   -- 2. try to find 'old one'
   local p
   for i, v in ipairs(self.lap:values())
   do
      if v.iid == iid and v.depracated and usp.prefix:contains(v.prefix)
      then
         if not assigned[v.binary_prefix]
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

         for i, v in ipairs(old[usp.ascii_prefix] or {})
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

   -- 3. assign /64 if possible
   if not p
   then
      p = self:find_new_from(iid, usp, assigned)
   end
   
   -- 4. hysteresis (sigh)
   -- first off, apply it only if within 'short enough' period of time from the start of the router
   if self.new_prefix_assignment > 0 and self:time_since_start() < self.new_prefix_assignment
   then
      -- look at number of rids we know; if it's 1, don't do anything
      -- for now
      if self.ridr:count() == 1
      then
         self:busy_until(self.new_prefix_assignment)
         self:d('hysteresis criteria filled - not assigning anything yet')
         return
      end
   end
   
   -- 5. if none available, skip (XXX probably this should be done before hysteresis check)
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
   o:assign_lap(iid)
end

function pa:time_since_start()
   return os.time() - self.start_time
end

-- child responsibility - return old assignment multimap, with
-- usp-prefix => {{iid, asp-prefix}, ...}
function pa:get_old_assignments()
   return self.old_assignments
end

function pa:find_assigned(usp)
   local t = mst.set:new()
   local b = usp.binary_prefix
   self:a(b, 'no usp.binary_prefix')
   for i, asp in ipairs(self.asp:values())
   do
      local ab = asp.binary_prefix
      self:a(ab, 'no asp.binary_prefix')
      if ipv6s.binary_prefix_contains(b, ab)
      then
         t:insert(ab)
      end
   end
   return t
end

function pa:find_new_from(iid, usp, assigned)
   local b = usp.binary_prefix
   local p

   self:a(assigned, 'assigned missing')
   self:a(b)

   -- if we're in freelist mode, just use it. otherwise, try to
   -- pick randomly first
   local t = usp.freelist
   if not t
   then
      -- initially, try the specified number times (completely
      -- arbitrary number) to figure a randomish prefix (based on the
      -- router id)
      
      -- (note: it should be big enough to make it unlikely that we
      -- have to produce a freelist, which in and of itself is
      -- expensive)
      for i=1,self.random_prefix_tries
      do
         local p = usp:get_random_binary_prefix(iid, i)
         if not assigned[p]
         then
            --self:d('find_new_from random worked iteration', i)
            local np = ipv6s.new_prefix_from_binary(p)
            self:a(usp.prefix:contains(np))
            return np
         end
      end
      
      -- ok, lookup failed; create freelist
      t = usp:create_prefix_freelist(assigned)
   end

   -- Now handle freelist; pick random item from there. We _could_
   -- try some sort of md5-seeded logic here too; however, I'm not
   -- convinced the freelist looks same in exhaustion cases anyway, so
   -- random choice is as good as any?
   self:a(t)
   local idx = mst.array_randindex(t)
   if not idx
   then
      self:d('not found in freelist', usp.prefix, #t)
      return
   end
   local v = t[idx]
   t:remove_index(idx)
   self:d('find_new_from picked index', idx, v)
   return v
end

-- 6.3.2
function pa:check_asp_conflicts(iid, asp)
   self:d('6.3.2 check_asp_conflicts', asp)
   for i, asp2 in ipairs(self.asp:values())
   do
      -- if conflict, with overriding rid is found, depracate prefix
      if asp2.ascii_prefix == asp.ascii_prefix and asp2.rid > asp.rid
      then
         -- as described in 6.3.3
         asp:depracate_lap(iid)
         return
      end
   end

   -- otherise mark it as valid
   asp.valid = true
end

-- 6.3.4
function pa:assign_other(iid, asp)
   self:d('6.3.4 assign_other', asp)
   -- if we get here, it's valid asp.. just question of what we need
   -- to do with lap
   asp.valid = true

   -- So we just fire up the assign_lap, it will ignore duplicate calls anyway

   -- Note: the verbiage about locally converted interfaces etc seems
   -- excessively strict in the draft.
   asp:assign_lap(iid)
end

function pa:matching_prefix_exists(filter)
   for i, usp in ipairs(self.usp:values())
   do
      if filter(usp) then return true end
   end
end

function pa:generate_ulaish(filter, filter_own, generate_prefix)
   -- i) first off, if we _do_ have usable prefixes, use them
   if self:matching_prefix_exists(filter)
   then
      self:d('something exists, generate_ulaish skipped')
      return
   end

   local rids = self.ridr:keys()

   -- ii) do we have highest rid? if not, generation isn't our job
   local highest_rid = mst.max(unpack(rids))
   --self:d('got rids', rids, highest_rid)

   local my_rid = self.rid
   if my_rid < highest_rid
   then
      return
   end

   -- iii) 'assignments'.. vague. skipped. XXX

   -- we should either create or maintain ULA-USP

   -- first off, see if we already have one
   local ownusps = self.usp[self.rid] or {}
   if #ownusps > 0
   then
      for i, usp in ipairs(ownusps)
      do
         if filter_own(usp)
         then
            usp.valid = true
         end
      end
      return
   end

   -- we don't

   -- handle hysteresis - if we have booted up recently, skip
   if #rids == 1
   then
      if self.new_ula_prefix > 0 and self:time_since_start() < self.new_ula_prefix
      then
         self:busy_until(self.new_ula_prefix)
         return
      end
   end

   -- generate usp
   local p = generate_prefix()
   usp:new{prefix=p, rid=my_rid, pa=self, valid=true}

   -- XXX store it on disk
end

function pa:route_to_rid(rid)
   return self.ridr[rid]
end

function pa:update_ifs_neigh()
   local client = self.client
   local rid = self.rid

   self:a(client, 'no client')

   -- store the index => if-object (and less material index => highest-rid)
   self.ifs = mst.map:new()
   self.neigh = mst.map:new()
   client:iterate_if(rid, function (ifo)
                        self:d('got if', ifo)
                        self.ifs[ifo.index] = ifo
                        local t = mst.map:new{}
                        client:iterate_ifo_neigh(rid, ifo, function (o)
                                                    local iid = o.iid
                                                    local rid = o.rid
                                                    self:d(' got neigh', o)
                                                    self:a(_valid_rid(rid))
                                                    self:a(_valid_iid(iid))
                                                    t[rid] = iid
                                                      end)
                        self.neigh[ifo.index] = t
                          end
                    )
end

function pa:get_ifs_neigh_hash()
   self:update_ifs_neigh()
   return create_hash(mst.repr{self.ifs, self.neigh})
end

function pa:busy_until(seconds_delta_from_start)
   -- XXX - add test cases to make sure this works correctly
   if not self.busy or self.busy > seconds_delta_from_start
   then
      self.busy = seconds_delta_from_start
   end
end

function pa:should_run()
   -- XXX - add test cases to make sure we do things 'correctly'
   -- (empirically, we seem to, but having test cases is better)
   local rid = self.rid
   local h = self:get_ifs_neigh_hash()
   if self.busy and self.busy <= self:time_since_start()
   then
      self:d('no longer busy - should run')
      self.busy = nil
   elseif h ~= self.last_ifs_neigh_hash
   then
      self:d('should run - ifs/neighs changed')
      
      self.last_ifs_neigh_hash = h
   elseif self.changes > 0
   then
      self:d('should run - changes > 0 (timeouts)')
   else
      local should
      -- check known USP's - if they are missing nh, that's valid
      -- reason too (should be anomalous, temporary condition)
      self.usp:foreach(function (ii, o) 
                          -- we never have nh if it's us (locals
                          -- handled per-if basis in elsa_pa)
                          if o.rid == rid then return end

                          -- not us => we should have nh, or
                          -- routing table is still in flux
                          local r = self:route_to_rid(o.rid) or {}
                          if not r.nh
                          then
                             self:d('should run - missing rid.nh info', o, r)
                             should = true
                          end
                          end)
      if not should
      then
         return
      end
   end
   -- one of the positive branches
   return true
end

function pa:run(d)
   self:d('run called')

   local client = self.client
   local rid = self.rid

   self:a(client, 'no client')

   d = d or {}
   if not d.checked_should
   then
      -- run it just in case => counters get reset etc
      self:should_run()
   end

   -- mark existing data invalid
   -- (laps have their own lifecycle governed via timeouts etc)
   self.asp:foreach(function (ii, o) o.valid = false end)
   self.usp:foreach(function (ii, o) o.valid = false end)
   self.ridr:keys():map(function (k) self.ridr[k]=false end)

   -- get the rid reachability
   client:iterate_rid(rid, function (o)
                         local rid = o.rid
                         self:d('got rid', o)
                         self:a(_valid_rid(rid), 'invalid rid', o)
                         self.ridr[rid] = o
                           end)

   -- get the usable prefixes from the 'client' [prefix => rid]
   client:iterate_usp(rid, function (o)
                         local prefix = o.prefix
                         local rid = o.rid
                         self:d('got usp', o)
                         self:a(_valid_rid(rid))
                         self:a(prefix)
                         self:add_or_update_usp(prefix, rid)
                           end)

   -- generate ULA prefix if necessary
   self:generate_ulaish(
      -- filter others' (without which this is pointless)
      function (usp)
         return usp.rid ~= self.rid and not usp.prefix:is_ula()
      end,

      -- filter own ula prefixes
      function (usp)
         return usp.rid == self.rid and usp.prefix:is_ula()
      end,

      -- produce a new prefix
      function ()
         local hwf = self.client:get_hwf(self.rid)
         local bits = create_hash(hwf)
         -- create binary prefix - first one 0xFC, 5 bytes from bits => /48
         local bp = ipv6s.ula_prefix .. string.sub(bits, 1, 5)
         local p = ipv6s.new_prefix_from_binary(bp)
         return p
      end
                       )

   -- drop those that are not valid immediately
   self:filtered_values_done(self.usp,
                             function (usp) return not usp.valid end)
   
   -- get the (remotely) assigned prefixes
   client:iterate_asp(rid, function (o)
                         local prefix = o.prefix
                         local iid = o.iid
                         local rid = o.rid
                         self:d('got asp', o)
                         self:a(prefix)
                         self:a(_valid_rid(rid))
                         self:a(_valid_iid(iid), 'invalid iid', iid)
                         self:add_or_update_asp(prefix, iid, rid)
                           end)

   -- drop expired remote assignments
   self:filtered_values_done(self.asp,
                             function (asp) 
                                self:a(asp.class == 'asp', asp, asp.class)
                                return asp:is_remote() and not asp.valid 
                             end)


   -- run the prefix assignment
   for iid, _ in pairs(self.ifs)
   do
      for i, usp in ipairs(self.usp:values())
      do
         self:a(usp.class == 'usp', usp, usp.class)
         local n = self.neigh[iid]
         self:a(n)
         self:run_if_usp(iid, n, usp)
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
      if o.ascii_prefix == prefix
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
      if o.ascii_prefix == prefix and o.iid == iid
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
