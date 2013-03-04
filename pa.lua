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
-- Last modified: Mon Mar  4 15:00:49 2013 mstenber
-- Edit time:     932 min
--

-- This is homenet prefix assignment algorithm, written using fairly
-- abstract data structures. The network abstraction object should
-- provide a way of doing the required operations, and should call us
-- whenever it's state changes.

-- client is expected to provide:
--  get_hwf(rid) => hardware fingerprint in string
--  iterate_rid(rid, f) => callback f with {rid=[, ifname=, nh=]}
--  iterate_usp(rid, f) => callback f with {prefix=, rid=}
--  iterate_asp(rid, f) => callback f with {prefix=, iid=, rid=}
--  iterate_asa(rid, f) => callback f with {prefix=, rid=}
--  iterate_if(rid, f) => callback f with if-object
--   iterate_ifo_neigh(rid, if-object, f) => callback with {iid=, rid=}

-- client can also override/subclass the lap class here within pa, to
-- provide the real assign/unassign/deprecation (by providing do_*
-- methods). once done, they should call Done/Error. if asynchronous,
-- they should also provide stop_* methods.

-- configuration parameters of note:

--  disable_ula - disable ALL ULA generation (we will use it if it is
--  provided by the network, though)

--  disable_ipv4 - disable IPv4 handling (both origination of IPv4 USP,
--  and assignment of local addresses)

--  disable_always_ula - disable constant ULA generation/use (if
--  disabled, ULA will be available if and only if no global prefixes
--  are available)

--  rid (or given to constructor)

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

-- which is the last ip# on a /24 reserved for routers; assumption is
-- that there WON'T be that many nodes on a link (although wireless
-- may surprise us at some point)
IPV4_PA_LAST_ROUTER=64

-- how many bits of the IPv4 prefix are dedicated to routers
-- IPV4_PA_LAST_ROUTER overrides this, but this is used as initial
-- search space; therefore, they should be ~correct - that is, 
-- 2^IPV4_PA_ROUTER_BITS =~ IPV4_PA_LAST_ROUTER
IPV4_PA_ROUTER_BITS=math.floor(math.log(IPV4_PA_LAST_ROUTER) / math.log(2))

local _null = string.char(0)

-- sanity checking
function _valid_rid(s)
   -- we use strings internally for test purposes
   return type(s) == 'string' or type(s) == 'number'
end

function _valid_iid(s)
   return type(s) == 'number'
end

function _valid_local_iid(pa, s)
   mst.a(pa and s, 'pa/s not specified', pa, s)
   return pa.ifs[s]
end

-- prefix handler base (used in lap, asp, usp)
ph = mst.create_class{class='ph'}

function ph:init()
   self:a(self.prefix)
   if type(self.prefix) == 'string' 
   then 
      self.prefix = ipv6s.new_prefix_from_ascii(self.prefix)
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
                   address=self.address,
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

function lap:find_usp()
   -- this might be worth caching, perhaps..?

   -- find the shortest (bit-mask-wise) usp which contains our prefix =>
   -- that one is the one we belong to
   local found, found_bits, bits
   self.pa.usp:foreach(function (x, usp)
                          if usp.prefix:contains(self.prefix)
                          then
                             bits = usp.prefix:get_binary_bits()
                             if not found or found_bits > bits
                             then
                                found = usp
                                found_bits = bits
                             end
                          end

                       end)
   return found
end

-- external API (which is just forwarded to the state machine)

function lap:assign()
   self:d('assign', self.assigned)
   self.sm:Assign()
end

function lap:unassign()
   self:d('unassign')
   self.sm:Unassign()
end

function lap:depracate()
   self:d('depracate')
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
   self.address = nil -- clear ipv4 address, if any
   self.sm:Done()
end

function lap:do_unassign()
   self:a(not self._is_done, 'called when done')
   self.pa:changed()
   self.assigned = false
   self.address = nil -- clear ipv4 address, if any
   -- (hopefully we have something better to replace it with)
   self.sm:Done()
end

-- assigned prefix

asp = ph:new_subclass{class='asp', mandatory={'prefix', 
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

function asp:get_liid()
   return self.liid or self.iid
end

function asp:find_lap()
   local iid = self:get_liid()
   self:d('find_lap')
   self:a(_valid_local_iid(self.pa, iid))
   self:a(self.class)
   self:a(self.pa, 'no pa?!?')
   local t = self.pa.lap[iid]
   for i, v in ipairs(t or {})
   do
      --self:d(' considering', v)
      if v.ascii_prefix == self.ascii_prefix
      then
         return v
      end
   end
end

function asp:find_or_create_lap()
   local iid = self:get_liid()
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
                                pa=self.pa}
end

function asp:assign_lap()
   local iid = self:get_liid()
   self:a(_valid_local_iid(self.pa, iid))
   self:a(self.class == 'asp')
   local lap = self:find_or_create_lap()
   lap:assign()
   lap.owner = self.rid == self.pa.rid and true or nil
end

function asp:depracate_lap()
   -- look up locally assigned prefixes (if any)
   local lap = self:find_lap()
   if not lap then return end
   lap:depracate()
end

function asp:unassign_lap()
   local iid = self:get_liid()
   -- look up locally assigned prefixes (if any)
   -- brute-force through the lap - if prefix is same, we're good
   for _, lap in ipairs(self.pa.lap[iid] or {})
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

-- subprefix sources can generate random prefixes within (using
-- self:get_desired_bits() as guidance to how long they should be,
-- provide their own freelist abstraction (which can be cleared as
-- needed), and some other niceties)
sps = ph:new_subclass{class='sps', mandatory={'prefix', 'pa'}}

function sps:repr_data()
   return mst.repr{prefix=self.ascii_prefix, desired_bits=self.desired_bits}
end

function sps:get_desired_bits()
   local bits = self.desired_bits
   self:a(bits, 'desired_bits not set')
   return bits
end

function sps:get_random_binary_prefix(iid, i)
   local b = self.binary_prefix
   local bl = self.prefix:get_binary_bits()
   local desired_bits = self:get_desired_bits()

   mst.a(bl > (#b-1) * 8 and bl <= #b * 8, "weird b<>bl", #b, bl)
   mst.a(bl <= desired_bits, 'invalid prefix length prefix<>wanted', self, desired_bits)

   i = i or 0
   -- get the rest of the bytes from md5
   local s = string.format("%s-%s-%s-%d", 
                           self.pa:get_hwf(), self.pa.ifs[iid].name, self.ascii_prefix, i)
   local sb = mst.create_hash(s)

   -- sub-byte handling of the bits available
   local v = string.byte(b, #b, #b)
   local v2 = string.byte(sb, 1, 1)
   for i=1,(8-bl%8)%8
   do
      if mst.bitv_is_set_bit(v2, i)
      then
         v = mst.bitv_xor_bit(v, i)
      end
   end
   local c = string.char(v)

   p = string.sub(b, 1, #b-1) .. c .. string.sub(sb, #b+1, desired_bits / 8)
   local got_bits = #p * 8
   self:a(got_bits == desired_bits, 'mismatch', got_bits, desired_bits)
   return p
end

function sps:create_prefix_freelist(assigned)
   if self.freelist then return self.freelist end

   local b = self.binary_prefix
   local t = mst.array:new()
   local desired_bits = self:get_desired_bits()
   local usp_bits = self.prefix:get_binary_bits()
   mst.a(desired_bits > 0)

   self.freelist = t

   if #b >= desired_bits/8
   then
      return t
   end

   -- use the last prefix as base, iterate through the whole usable prefix
   local p = b .. string.rep(string.char(0), desired_bits/8-#b)
   local sp = p
   while true
   do
      p = ipv6s.binary_prefix_next_from_usp(b, usp_bits, p, desired_bits)
      self:a(#p == desired_bits/8, "binary_prefix_next_from_usp bugs?")

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

function sps:find_new_from(iid, assigned)
   local b = self.binary_prefix
   local p

   self:a(assigned, 'assigned missing')
   self:a(b)

   -- if we're in freelist mode, just use it. otherwise, try to
   -- pick randomly first
   local t = self.freelist
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
         local p = self:get_random_binary_prefix(iid, i)
         if not assigned[p]
         then
            local np = ipv6s.new_prefix_from_binary(p)
            self:d('find_new_from random worked iteration', i, self.pa.rid, iid, np)
            self:a(self.prefix:contains(np))
            return np
         end
      end
      
      -- ok, lookup failed; create freelist
      t = self:create_prefix_freelist(assigned)
   end

   -- Now handle freelist; pick random item from there. We _could_
   -- try some sort of md5-seeded logic here too; however, I'm not
   -- convinced the freelist looks same in exhaustion cases anyway, so
   -- random choice is as good as any?
   self:a(t)
   local idx = mst.array_randindex(t)
   if not idx
   then
      self:d('not found in freelist', self.prefix, #t)
      return
   end
   local v = t[idx]
   t:remove_index(idx)
   self:d('find_new_from picked index', idx, v)
   return v
end


-- usable prefix, can be either local or remote (no behavioral
-- difference though?)
usp = sps:new_subclass{class='usp', mandatory={'prefix', 'rid', 'pa'}}

function usp:init()
   -- superclass init
   sps.init(self)

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

function usp:get_desired_bits()
   if self.prefix:is_ipv4()
   then
      return 96 + 24 -- /24
   else
      return 64
   end
end


-- main prefix assignment class


pa = mst.create_class{class='pa', 
                      lap_class=lap, 
                      mandatory={'rid'},
                      -- tunable parameters
                      new_prefix_assignment=0,
                      new_ula_prefix=0,
                      random_prefix_tries=5,
                      time=ssloop.time,
                     }

function pa:init()
   -- set the sps subclasses' random prefix #
   -- TODO - this isn't very pretty (but mostly works)
   sps.random_prefix_tries = self.random_prefix_tries

   -- locally assigned prefixes - iid => list
   self.lap = mst.multimap:new()

   -- rid reachability => true/false (reachable right now)
   self.ridr = mst.map:new()

   -- all asp data, ordered by prefix
   self.asp = mst.multimap:new()
   self.vsa = mst.validity_sync:new{t=self.asp, single=true}

   -- all usp data, ordered by prefix
   self.usp = mst.multimap:new()
   self.vsu = mst.validity_sync:new{t=self.usp, single=true}

   -- init changes to 0 here (it's cleared at _end_ of each pa:run,
   -- but timeouts may cause it to become non-zero before next pa:run)
   self.changes = 0

   -- store when we started, for hysteresis calculations
   self.start_time = self.time()
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
   local todo
   h:foreach(function (k, o)
                if not f or f(o) 
                then 
                   todo = todo or {}
                   table.insert(todo, o)
                end
             end)
   if todo
   then
      for i, o in ipairs(todo)
      do
         self:d('done with', o)
         o:done() 
      end
   end
end

function pa:get_local_asp_values()
   self:a(self)
   self:a(self.class=='pa')

   local l = self.asp[self.rid]
   if l then l = mst.table_copy(l) end
   return l or {}
end

function pa:get_local_usp_values()
   self:a(self)
   self:a(self.class=='pa')
   local l = self.usp[self.rid] 
   if l then l = mst.table_copy(l) end
   return l or {}
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


   local ifo = self.ifs[iid]
   if ifo.disable
   then
      self:d(' PA disabled')
      return
   end

   -- skip if it's IPv4 prefix + interface is disabled for v4
   if usp.prefix:is_ipv4() and (ifo.disable_v4 or ifo.external)
   then
      self:d(' v4 PA disabled')
      return
   end

   -- skip ULA if it's external
   if usp.prefix:is_ula() and ifo.external
   then
      self:d(' ULA disabled (external)')
      return
   end

   -- Alg from 6.3.. steps noted 
   
   -- 1. if some shorter prefix contains this usp, skip
   local containing_prefix_found
   self.usp:foreach(function (k, v)
                       -- TODO-DRAFT - complain that this seems broken
                       -- (BCP38 stuff might make it not-so-working?)
                       if v.ascii_prefix ~= usp.ascii_prefix 
                          and v.prefix:contains(usp.prefix)
                       then
                          containing_prefix_found = true
                       end

                    end)
   if containing_prefix_found
   then
      self:d('skipped, containing prefix found')
      return
   end

   -- (skip 2. - we don't really care about neighbors)

   -- 3. determine highest rid of already assigned prefix on the link
   local own
   local highest
   
   self.asp:foreach(function (k, asp)
                       --self:d(' considering', asp)
                       if ((asp.rid == rid and iid == asp.iid) 
                           or neigh[asp.rid] == asp.iid) 
                           and usp.prefix:contains(asp.prefix)
                       then
                          self:d(' fitting', asp)
                          if not highest or highest.rid < asp.rid
                          then
                             highest = asp
                          end
                          if asp.rid == rid
                          then
                             own = asp
                          end
                       end
                    end)

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

      -- note the local interface identifier so it can be used
      -- appropriately by the asp class's methods
      highest.liid = iid

      -- zap anything else we might have
      self:eliminate_other_lap(iid, usp, highest)

      self:assign_other(iid, highest)
      return
   end

   -- (iii) no assignment by anyone, highest rid?
   -- TODO-DRAFT - should we check for AC-enabled neighbors here only?
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
   local lap
   self:d('6.3.1 assign_own', iid, usp)
   self:a(_valid_local_iid(self, iid))

   -- 1. find already assigned prefixes
   assigned = self:find_assigned(usp)
   usp.freelist = nil -- clear old freelist, if any

   -- 2. try to find 'old one'
   local p
   for i, v in ipairs(self.lap[iid] or {})
   do
      if usp.prefix:contains(v.prefix)
      then
         if v.assigned or not assigned[v.binary_prefix]
         then
            self:d('found old lap', v)
            p = v.prefix
            lap = v
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

   -- 3. hysteresis (sigh)
   -- first off, apply it only if within 'short enough' period of time from the start of the router
   if not p and self.new_prefix_assignment > 0 and self:time_since_start() < self.new_prefix_assignment
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
   
   -- 4. assign /64 if possible
   if not p
   then
      p = usp:find_new_from(iid, assigned)
   end
   
   -- 5. if none available, skip
   -- (TODO-DRAFT in draft, the order is assign new + hysteresis + this)
   if not p
   then
      return
   end

   -- get rid of potentially duplicate lap's, if any
   self:eliminate_other_lap(iid, usp, nil, lap)


   -- 6. if assigned, mark as valid + send AC LSA
   local o = asp:new{prefix=p,
                     pa=self,
                     iid=iid,
                     rid=self.rid}
   o:assign_lap()
end

function pa:eliminate_other_lap(iid, usp, asp, lap)
   self:a(iid, 'iid missing', iid, usp, asp)

   -- depracate immediately any other prefix that is on this iid,
   -- with same USP as us 
   local is_ipv4 = not usp or usp.prefix:is_ipv4()
   local lap = lap or (asp and asp:find_lap())
   
   -- (nondeterministic) test case for this in elsa_pa_stress.lua
   for i, lap2 in ipairs(self.lap[iid] or {})
   do
      self:d('eliminate_other_lap considering', lap2)
      -- Only one IPv4 prefix can be active per-interface =>
      -- when adding something new, old one disappears off the map immediately
      -- anyway regardless of USP match
      if ((is_ipv4 and lap2.address) 
          or (usp and usp.prefix:contains(lap2.prefix))) and lap2 ~= lap
      then
         self:d(' matched -> depracate')
         lap2:depracate()
      end
   end
end

function pa:time_since_start()
   return self.time() - self.start_time
end

-- child responsibility - return old assignment multimap, with
-- usp-prefix => {{iid, asp-prefix}, ...}
function pa:get_old_assignments()
   return self.old_assignments
end

function pa:find_assigned(usp)
   local t = mst.set:new()
   self.asp:foreach(function (k, asp)
                       local ab = asp.binary_prefix
                       self:a(ab, 'no asp.binary_prefix')
                       if usp.prefix:contains(asp.prefix)
                       then
                          t:insert(ab)
                       end

                    end)
   return t
end

-- 6.3.2
function pa:check_asp_conflicts(iid, asp)
   self:d('6.3.2 check_asp_conflicts', asp)
   
   local t 
   local found_conflict
   self.asp:foreach(function (k, asp2)
                       -- if conflict, with overriding rid is found, 
                       -- depracate prefix
                       if asp2.ascii_prefix == asp.ascii_prefix and asp2.rid > asp.rid
                       then
                          found_conflict = true
                       end
                    end)
   
   if found_conflict
   then
      -- as described in 6.3.3
      self:a(asp:get_liid() == iid)
      asp:depracate_lap()
      return
   end

   -- otherise mark it as valid
   self.vsa:set_valid(asp)
end

-- 6.3.4
function pa:assign_other(iid, asp)
   self:d('6.3.4 assign_other', asp)
   -- if we get here, it's valid asp.. just question of what we need
   -- to do with lap
   self.vsa:set_valid(asp)

   -- So we just fire up the assign_lap, it will ignore duplicate calls anyway

   -- Note: the verbiage about locally converted interfaces etc seems
   -- excessively strict in the draft.
   local liid = asp:get_liid()
   self:a(liid == iid, 'asp iid mismatch', liid, iid)
   asp:assign_lap()
end

function pa:find_usp_matching(filter)
   local found
   self.usp:foreach(function (k, usp)
                       if filter(usp) then found = usp end
                    end)
   return found
end

function pa:generate_ulaish(filter, filter_own, generate_prefix, desc)
   -- i) first off, if we _do_ have usable prefixes from someone else,
   -- use them
   if self:find_usp_matching(filter)
   then
      self:d('something exists, generate_ulaish skipped', desc)
      return
   end

   self:d('generate_ulaish', desc)

   local rids = self.ridr:keys()

   -- ii) do we have highest rid? if not, generation isn't our job
   local highest_rid = mst.max(unpack(rids))
   --self:d('got rids', rids, highest_rid)

   local my_rid = self.rid
   if my_rid < highest_rid
   then
      self:d(' higher rid exists, skipping')
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
            self:d(' keeping', usp)
            self.vsu:set_valid(usp)
            return
         end
      end
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
   self:d(' generated prefix', p)
   usp:new{prefix=p, rid=my_rid, pa=self}

   -- XXX store it on disk
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

function pa:get_ifs_neigh_state()
   -- XXX - determine if this should in truth use hash; but if sw fallback, it's _slow_
   self:update_ifs_neigh()
   local s = mst.repr{self.ifs, self.neigh}
   s = mst.create_hash_if_fast(s)
   return s
end

function pa:busy_until(seconds_delta_from_start)
   if not self.busy or self.busy > seconds_delta_from_start
   then
      self.busy = seconds_delta_from_start
   end
end

function pa:should_run()
   local rid = self.rid
   local h = self:get_ifs_neigh_state()
   if self.busy
   then
      if self.busy <= self:time_since_start()
      then
         self:d('no longer busy - should run')
         self.busy = nil
      else
         self:d('still busy - should run')
      end
      return true
   end
   if h ~= self.last_ifs_neigh_state
   then
      self:d('should run - ifs/neighs changed')
      
      self.last_ifs_neigh_state = h
      return true
   end
   if self.changes > 0
   then
      self:d('should run - changes > 0 (timeouts)')
      return true
   end
end

function pa:get_hwf()
   if not self.hwf
   then
      self.hwf = self.client:get_hwf(self.rid)
   end
   return self.hwf
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

   -- must have interfaces present
   mst.a(self.ifs)

   -- mark existing data invalid
   -- (laps have their own lifecycle governed via timeouts etc)
   self.vsu:clear_all_valid()
   self.vsa:clear_all_valid()
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
   if not self.disable_ula
   then
      self:generate_ulaish(
         -- what prevents ula from happening?
         function (usp)
            -- we ignore ipv4 usps 
            if usp.prefix:is_ipv4()
            then
               return
            end
            
            -- we ignore non-v4 non-ULA, if we're in generate always mode
            if not self.disable_always_ula
            then
               if not usp.prefix:is_ula()
               then
                  return
               end
            end


            -- a) something from someone else (don't generate if someone
            -- else already has _something_)
            if usp.rid ~= self.rid
            then
               return true
            elseif not usp.prefix:is_ula()
            then
               -- b) own non-ula non-v4
               return true
            end
         end,

         -- filter own ula prefixes
         function (usp)
            return usp.rid == self.rid and usp.prefix:is_ula()
         end,

         -- produce a new prefix
         function ()
            local hwf = self:get_hwf()
            local bits = mst.create_hash(hwf)
            -- create binary prefix - first one 0xFC, 5 bytes from bits => /48
            local bp = ipv6s.ula_prefix .. string.sub(bits, 1, 5)
            local p = ipv6s.new_prefix_from_binary(bp)
            return p
         end,
         'ULA')
   end

   if not self.disable_ipv4
   then

      -- generate IPv4 prefix if necessary
      self:generate_ulaish(
         -- what prevents our v4 from happening?
         function (usp)
            -- XXX - consider if we should implement _real_ priority
            -- ordering here, or just stick to 'someone publishes one ->
            -- life is good'
            if usp.rid ~= self.rid and usp.prefix:is_ipv4() 
            then
               return true
            end
         end,

         -- filter own v4 prefixes
         function (usp)
            return usp.rid == self.rid and usp.prefix:is_ipv4()
         end,

         -- produce a new prefix
         function ()
            -- XXX - implement real algorithm here, instead of just 10./8
            -- (it _works_, but isn't elegant)
            local p = ipv6s.new_prefix_from_ascii('10.0.0.0/8')
            return p
         end,
         'V4 USP')

   end



   -- drop those that are not valid immediately
   self:filtered_values_done(self.usp,
                             function (usp) return usp.invalid end)
   
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
                                return asp:is_remote() and asp.invalid 
                             end)


   -- run the prefix assignment
   for iid, _ in pairs(self.ifs)
   do
      self.usp:foreach(function (k, usp)
                          self:a(usp.class == 'usp', usp, usp.class)
                          local n = self.neigh[iid]
                          self:a(n)
                          self:run_if_usp(iid, n, usp)
                       end)
   end

   -- handle the expired local assignments
   for i, asp in ipairs(self:get_local_asp_values())
   do
      if asp.invalid
      then
         asp:done()
      end
   end

   if not self.disable_ipv4
   then
      -- sanity check - make sure we don't have multiple IPv4
      -- prefixes on interface active at any point in time
      local done = {}
      -- handle local IPv4 address assignment algorithm
      for i, lap in ipairs(self.lap:values())
      do
         if lap.assigned and lap.prefix:is_ipv4()
         then
            local prev = done[lap.ifname]
            self:a(not prev,
                   'two IPv4 LAP on same interface', 
                   prev, lap)
            self:handle_ipv4_lap_address(lap)
            done[lap.ifname] = lap
         end
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

function pa:handle_ipv4_lap_address(lap)
   -- there can be only one v4 lap per interface 
   -- (ever only one USP => at most one LAP per interface)

   local rid = self.rid

   self:d('handle_ipv4_lap_address', lap)

   -- XXX implement this effectively
   local assigned = mst.map:new{}
   
   -- store _all_ assignments, and in general the highest rid one if
   -- there's conflicts
   self.client:iterate_asa(rid, function (o)
                              local b = o.prefix:get_binary()
                              local prev = assigned[b]
                              if not prev or prev < o.rid
                              then
                                 assigned[b] = o.rid
                              end
                                end)


   -- if we have assignment, and it is valid (assigned[address] == us), nop
   if lap.address and assigned[lap.address:get_binary()]
   then
      self:d(' happy with existing one')
      return
   end

   local p = ipv6s.new_prefix_from_binary(lap.prefix:get_binary() .. _null,
                                          128 - IPV4_PA_ROUTER_BITS)

   -- ok, we either don't have assignment, or someone with higher rid
   -- wants _our_ address. let's not fight. try to generate a new one.
   self:eliminate_other_lap(lap.iid, nil, nil, lap) 

   local s = sps:new{prefix=p, desired_bits=128, pa=self}

   -- we do this loop to make sure result is reasonable; typically
   -- there should be just ~0-1 iterations (0 if pool full, 1
   -- otherwise)
   while true
   do
      local p = s:find_new_from(lap.iid, assigned)
      if not p
      then
         -- no address available
         -- clear old address if any
         if lap.address
         then
            self:d(' cleared old, unable to allocate new')
            lap.address = nil
            self:changed()
         end
         return
      end
      local b = p:get_binary()
      mst.a(#b == 16, 'invalid result?', #b)
      -- consider the last byte - is it >= 1, <= 64?
      -- (64-254 reserved for DHCPv4 hosts, 255 = broadcast)
      local lb = string.byte(b, 16, 16)
      if lb >= 1 and lb <= IPV4_PA_LAST_ROUTER
      then
         lap.address = p
         self:d(' assigned', p)
         self:changed()
         return
      else
         assigned[b] = true
      end
   end
end

local function _ascii_prefix(prefix)
   if type(prefix) == 'table'
   then
      return prefix:get_ascii()
   end
   mst.a(type(prefix)=='string', 'wierd prefix - should be ascii')
   return prefix
end

function pa:add_or_update_usp(prefix, rid)
   local ascii_prefix = _ascii_prefix(prefix)

   self:a(self.ridr[rid], 'sanity-check failed - rid not reachable', rid)
   for i, o in ipairs(self.usp[rid] or {})
   do
      if o.ascii_prefix == ascii_prefix
      then
         -- XXX - make a test case that this actually occurs (i.e. old
         -- ULAs and IPv4 assignments disappear if they're no longer
         -- relevant)

         -- remote ones are valid if we see them
         -- local ones are typically, unless they're ULA/IPv4
         -- (those have to be validated later on)
         if rid ~= self.rid or (not o.prefix:is_ula() and not o.prefix:is_ipv4())
         then
            self:d(' updated old usp')
            self.vsu:set_valid(o)
         end
         return
      end
   end
   self:d(' adding new usp')
   usp:new{prefix=prefix, rid=rid, pa=self}
end

function pa:get_asp(prefix, iid, rid)
   local ascii_prefix = _ascii_prefix(prefix)

   --mst.a(type(prefix)=='string', 'wierd prefix - should be ascii')
   for i, o in ipairs(self.asp[rid] or {})
   do
      if o.ascii_prefix == ascii_prefix and o.iid == iid
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
      self:a(o:is_remote(), 'non-remote asp?!?')
      self.vsa:set_valid(o)
      return
   end
   self:a(rid ~= self.rid, 'should not get own asp')
   self:d(' adding new asp')
   asp:new{prefix=prefix, iid=iid, rid=rid, pa=self}
end

function pa:changed()
   self.changes = self.changes + 1
end
