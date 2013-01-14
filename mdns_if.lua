#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_if.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Jan 10 14:37:44 2013 mstenber
-- Last modified: Thu Jan 10 16:52:52 2013 mstenber
-- Edit time:     62 min
--

require 'mst'
require 'dnscodec'
require 'dnsdb'
require 'mdns_const'

module(..., package.seeall)

-- probing states (waiting to send message N)
STATE_P1='p1'
STATE_P2='p2'
STATE_P3='p3'
STATE_PW='pw'
-- => a1 if no replies

-- waiting to start probe again
-- STATE_WP1='wp1' 
-- as we treat failed probes 'definitely not our problem', there isn't
-- conflict here.. :-p

-- announce states - waiting to announce (based on spam-the-link frequency)
STATE_A1='a1'
STATE_A2='a2'

-- waiting to announce ttl 0
STATE_D1='d1'
-- waiting to die after ttl 0 sent (1 second)
STATE_D2='d0'

-- when do we call the 'run' method for a state after we have entered the state?
STATE_DELAYS={[STATE_P1]={0, 250},
              [STATE_P2]={250, 250},
              [STATE_P3]={250, 250},
              [STATE_PW]={250, 250},
              --[STATE_WP1]={1000, 1000},
              [STATE_A1]={20, 120},
              [STATE_A2]={1000, 1000},
              [STATE_D1]={20, 120},
              [STATE_D2]={1000, 1000},
}

function send_probes_cb(self)
   -- send _all_ probes, and implicitly advance them to next step too
   self:send_probes()
end

function send_announces_cb(self)
   self:send_announces()
end

STATE_CALLBACKS={[STATE_P1]=send_probes_cb,
                 [STATE_P2]=send_probes_cb,
                 [STATE_P3]=send_probes_cb,
                 [STATE_A1]=send_announces_cb,
                 [STATE_A2]=send_announces_cb,
}

NEXT_STATES={[STATE_P1]=STATE_P2,
             [STATE_P2]=STATE_P3,
             [STATE_P3]=STATE_PW,
             [STATE_PW]=STATE_A1,
             --[STATE_WP1]=STATE_P1,
             [STATE_A1]=STATE_A2,
             [STATE_A2]=false,
             [STATE_D1]=STATE_D2,
}

-- when should we send announce-like message?
announce_states = {[STATE_A1]=true, [STATE_A2]=true}

-- when should we send probe-like message?
probe_states = {[STATE_P1]=true, [STATE_P2]=true, [STATE_P3]=true}


-- field which indicates when this was received
FIELD_RECEIVED='received_time'
FIELD_SENT_MCAST='sent_mcast_time'

-- utility functions
local function msg_has_qu_qd(msg)
   for i, q in ipairs(msg.qd)
   do
      if q.qu then return true end
   end
end

local function match_q_rr(q, rr)
   return (q.qtype == dns_const.TYPE_ANY or q.qtype == rr.rtype) 
      and (q.qclass == dns_const.CLASS_ANY or q.qclass == rr.rclass) 
      and dnsdb.ll_equal(q.name, rr.name)
end

local function match_q_q(q, o)
   return q.qtype == o.qtype 
      and q.qclass == o.qclass
      and dnsdb.ll_equal(q.name, o.name)
end

local function convert_anish_to_kas(kas)
   if not kas then return end
   if dnsdb.ns:is_instance(kas) then return kas end
   -- on-the-fly convert list of answers to dnsdb:ns
   local tns = dnsdb.ns:new{}
   mst.a(type(kas) == 'table', 'weird kas', kas)
   for i, a in ipairs(kas)
   do
      tns:insert_rr(a)
   end
   return tns
end

local function kas_matches_rr(kas, rr)
   if not kas then return end
   local orr = kas:find_exact_rr(rr)
   if not orr then return end

   -- finally, ttl must be >= half.. but if not set, it's just general
   -- availability check and we pretend ttl is valid
   if not rr.ttl then return true end

   -- rr = propsed answer
   -- orr = what we got in KAS
   local r = orr.ttl >= rr.ttl / 2
   mst.d('kas_matches_rr - ttl check', r, orr.ttl, rr.ttl)
   return r
end

function iterate_ns_matching_query(ns, q, kas, f)
   local matched
   local found_cf

   kas = convert_anish_to_kas(kas)
   mst.d('iterate_ns_matching_query', kas)
   --mst.d('iterate_ns_matching_query', kas, q, kas:values())

   for i, rr in ipairs(ns:find_rr_list_for_ll(q.name))
   do
      if rr.cache_flush
      then
         found_cf = true
      end
      if match_q_rr(q, rr)
      then  
         matched = true
         if not kas_matches_rr(kas, rr)
         then
            --mst.d(' calling callback', rr)
            f(rr)
         end
      end
   end
   -- if no match, _but_ we own the name
   -- => look up for negative NSEC 
   -- (assuming this wasn't already NSEC query, of course)
   if found_cf and not matched 
      and q.qtype ~= dns_const.TYPE_NSEC
   then
      iterate_ns_matching_query(ns, {
                                   name=q.name,
                                   qtype=dns_const.TYPE_NSEC,
                                   qclass=q.qclass,
                                    }, kas, f)
   end
end

function iterate_ns_rr(ns, rr, f, similar, equal)
   for i, rr2 in ipairs(ns:find_rr_list_for_ll(rr.name))
   do
      if rr.rtype == rr2.rtype and rr2:contained(rr)
      then
         local iseq = rr2:equals(rr)
         if (similar and not iseq) or (equal and iseq)
         then
            f(rr2)
         end
      end
   end
end


-- mdns for single interface; leveraged by mdns_core, and subclassable
-- if needed

-- per-if structure, which does most of the logic and has
-- per-structure data
mdns_if = mst.create_class{class='mdns_if',
                           mandatory={'ifname', 'parent'}}

function mdns_if:init()
   self.time = self.parent.time
   self.sendto = self.parent.sendto
   self.cache = dnsdb.ns:new{}
   self.own = dnsdb.ns:new{}
   self.pending = mst.set:new{}
end

function mdns_if:repr_data()
   return self.ifname
end

function mdns_if:run_own_states()
   local now = self.time()
   local c = 0
   mst.a(type(now) == 'number', now)
   local ns = self.own
   local pending
   ns:foreach(function (rr)
                 if rr.state
                 then
                    if rr.wait_until and rr.wait_until <= now then rr.wait_until = nil end

                    if not rr.wait_until
                    then
                       pending = pending or {}
                       pending[rr] = rr.state
                    end
                 end
              end)
   if pending
   then
      for rr, state in pairs(pending)
      do
         if rr.state == state
         then
            self:run_state(rr)
            c = c + 1
         end
      end
   end
   return c
end


function mdns_if:run_expire()
   local pending
   local now = self.time()

   self.own:foreach(function (rr)
                       if rr.valid and rr.valid <= now
                       then
                          self:d('[own] getting rid of', rr)
                          -- get rid of the entry
                          if not rr.cache_flush
                          then
                             pending = pending or {}
                             table.insert(pending, rr)
                             rr.ttl = 0
                          end
                          self.own:remove_rr(rr)
                       end
                    end)

   -- get rid of rr's that have expired
   self.cache:foreach(function (rr)
                         if rr.valid <= now
                         then
                            self:d('[cache] getting rid of', rr)
                            self.parent:expire_rr(rr)
                            self.cache:remove_rr(rr)
                         end
                      end)

   if pending
   then
      self:d('sending expire ttl=0 for #pending', #pending)
      -- send per-interface 'these are gone' fyi messages
      local s = dnscodec.dns_message:encode{an=pending, 
                                            h=MDNS_DEFAULT_RESPONSE_HEADER}
      local dst = MDNS_MULTICAST_ADDRESS .. '%' .. self.ifname
      self.parent.sendto(s, dst, MDNS_PORT)
   end
end

function mdns_if:run_send_pending()
   local pending
   local q = self.pending
   local now = self.time()

   for e, _ in pairs(q)
   do
      local t = self:schedule_for_e_in_q(e, q)
      if t <= now
      then
         pending = pending or {}
         table.insert(pending, e)
         q:remove(e)
      end
   end
   if pending
   then
      self:send_delayed_multicast(pending)
   end
end

function mdns_if:run()
   -- iteratively run through the object states until all are waiting
   -- for some future timestamp
   while self:run_own_states() > 0 do end
   
   -- expire old records
   self:run_expire()

   -- send delayed multicast queries and responses
   self:run_send_pending()
end

function mdns_if:split_qd_to_qu_nqu(msg)
   local qu = {}
   local nqu = {}
   local now = self.time()
   local ns = self.own
   function is_qu(q)
      if not q.qu
      then
         return false
      end
      -- it's qu - but what about
      -- the answers?  if one or
      -- more of the answers
      -- looks multicast worthy,
      -- then we pretend it's nqu
      local found 
      iterate_ns_matching_query(ns, q, msg.an,
                                function (rr)
                                   local last = rr[FIELD_SENT_MCAST]
                                   if not last or last < (now-rr.ttl/4)
                                   then
                                      found = true
                                   end
                                end)
      -- if found - pretend it's nqu
      return not found
   end
   return mst.array_filter2(msg.qd, is_qu)
end

function mdns_if:find_own_matching_queries(ql, an)
   local r = mst.set:new{}
   local ns = self.own
   local kas = convert_anish_to_kas(an)
   for i, q in ipairs(ql)
   do
      iterate_ns_matching_query(ns, q, kas, 
                                function (rr)
                                   r:insert(rr)
                                end)
   end
   return r:keys()
end

function mdns_if:copy_rrs_with_updated_ttl(rrl, unicast)
   local r = {}
   local now = self.time()
   for i, rr in ipairs(rrl)
   do
      self:a(rr.valid)
      local ttl = math.floor(rr.valid-now)
      if not unicast 
      then
         if rr[FIELD_SENT_MCAST] and rr[FIELD_SENT_MCAST] > (now - 1)
         then
            ttl = 0
         elseif rr[FIELD_RECEIVED] and rr[FIELD_RECEIVED] > (now - 1)
         then
            ttl = 0
         elseif ttl > 0
         then
            -- mark it sent
            rr[FIELD_SENT_MCAST] = now
         end
      end
      if ttl > 0
      then
         local n = mst.table_copy(rr)
         n.ttl = ttl
         table.insert(r, n)
      end
   end
   return r
end

function mdns_if:determine_ar(an, kas)
   local ar = {}
   local all = dnsdb.ns:new{}
   local ns = self.own

   -- initially, seed 'all' with whatever is already in answer; we 
   -- do NOT want to send those
   for i, a in ipairs(an)
   do
      all:insert_rr(a)
   end
   function push(t1, t2)
      for i, a in ipairs(an)
      do
         if a.rtype == t1 
            and not all:find_rr{name=a.name, rtype=t2, rclass=a.rclass}
            and not kas_matches_rr(kas, {name=a.name, rtype=t2, rclass=a.rclass})
         then
            -- if we have something like this, cool, let's add it
            iterate_ns_matching_query(ns,
                                      {name=a.name,
                                       qtype=t2,
                                       qclass=a.rclass},
                                      kas,
                                      function (rr)
                                         if not all:find_rr(rr) 
                                            and not kas_matches_rr(kas, rr)
                                         then
                                            all:insert_rr(rr)
                                            table.insert(ar, rr)
                                         end
                                      end)
         end
      end
   end
   push(dns_const.TYPE_A, dns_const.TYPE_AAAA)
   push(dns_const.TYPE_AAAA, dns_const.TYPE_A)
   return ar
end

function mdns_if:send_reply(an, kas, id, dst, dstport, unicast)
   -- ok, here we finally reduce duplicates, update ttl's, etc.
   an = self:copy_rrs_with_updated_ttl(an, unicast)
   if #an == 0 then return end

   -- we also determine additional records
   local ar = self:determine_ar(an, kas)
   ar = self:copy_rrs_with_updated_ttl(ar, unicast)
   -- ok, we have valid things to send with >0 ttl; here we go!
   local o = {an=an, ar=ar}
   local h = {}
   o.h = h

   h.id = id
   h.qr = true
   h.aa = true

   local s = dnscodec.dns_message:encode(o)
   mst.d('sending reply', o)
   self.sendto(s, dst, dstport)

end

function mdns_if:send_multicast_query(qd, kas, ns)
   local dst = MDNS_MULTICAST_ADDRESS .. '%' .. self.ifname
   local an
   if kas
   then
      local oan = kas:values()
      -- pretend to be unicast - we don't want the sent timestamps
      -- disturbed by stuff that doesn't update neighbor caches
      an = self:copy_rrs_with_updated_ttl(oan, true)
      mst.d('kas ttl update', #oan, #an)
   end
   local s = dnscodec.dns_message:encode{qd=qd, an=an, ns=ns}
   self.sendto(s, dst, MDNS_PORT)
end

function mdns_if:handle_unicast_query(msg, addr, srcport)
   self:d('handle_unicast_query', addr, srcport)
   -- given the 'own' data on interface, use that (and only that) to reply
   -- if nothing to reply, do not retry at all!
   
   -- no rate limiting or anything here, we just brutally reply whenever
   -- someone unicasts us (we're nice like that)

   --mst.d('msg.an', msg.an)
   local kas = convert_anish_to_kas(msg.an)
   local an = self:find_own_matching_queries(msg.qd, kas)
   local src = addr .. '%' .. self.ifname
   self:send_reply(an, kas, msg.h.id, src, srcport, true)
end

function mdns_if:query(q, rep)
   local p = self.pending

   -- first off, if we have already this scheduled, forget about it
   if not rep
   then
      for i, e in ipairs(p)
      do
         if e.query and match_q_q(e.query, q)
         then
            mst.d('duplicate query, skipping', q)
            return
         end
      end
   end

   local delay = mst.randint(20, 120)/1000.0 
   -- rep indicates delay of NEXT call, and should start at 0/true
   if rep
   then
      if rep == 0 or rep == true
      then
         rep = 1
      else
         delay = delay + rep
         rep = rep * 2
      end
   end
   local now = self.time()
   local when = now + delay
   local latest = when + 0.5
   mst.d(now, 'adding query', when, latest, q, rep)
   p:insert{when=when, latest=latest, query=q, rep=rep}
end

function mdns_if:start_query(q)
   self:query(q, true)
end

function mdns_if:stop_query(q)
   local p = self.pending
   for i, e in ipairs(p)
   do
      if e.query and match_q_q(e.query, q)
      then
         p:remove(e)
      end
   end
end

function mdns_if:send_delayed_multicast_queries(ql)
   if #ql == 0 then return end
   local qd = mst.array:new{}
   local ns = self.own
   local nsc = self.cache
   local kas = dnsdb.ns:new{}
   local now = self.time()

   mst.d('send_delayed_multicast_queries', #ql)
   -- note: we _shouldn't_ have duplicate queries, and even if
   -- we do, it doesn't really _matter_.. 
   function maybe_insert_kas(rr)
      -- if too much time has expired, don't bother
      if rr.valid_kas and rr.valid_kas < now
      then
         mst.d('valid_kas < now, skipped')
         return
      end
      -- if it's already in, don't bother
      if kas:find_rr(rr)
      then
         mst.d('already in kas')
         return
      end
      mst.d('new kas', rr)
      kas:insert_rr(rr)
   end
   for i, e in ipairs(ql)
   do
      local q = e.query 
      qd:insert(q)
      iterate_ns_matching_query(ns, q, kas, maybe_insert_kas)
      iterate_ns_matching_query(nsc, q, kas, maybe_insert_kas)
      if e.rep
      then
         self:query(q, e.rep)
      end
   end
   self:send_multicast_query(qd, kas, nil)
end

function mdns_if:send_delayed_multicast_replies(q)
   if #q == 0 then return end
   mst.d('send_delayed_multicast_replies', #q)

   -- basic idea is, we populate an based on queries we have;
   -- and then ar with stuff already not covered in one pass
   local full_an = mst.array:new{}
   for i, e in ipairs(q)
   do
      local msg = e.msg
      local kas = convert_anish_to_kas(msg.an)
      local an = self:find_own_matching_queries(msg.qd, kas)
      full_an:extend(an)
   end

   local dst = MDNS_MULTICAST_ADDRESS .. '%' .. self.ifname
   self:send_reply(full_an, nil, 0, dst, MDNS_PORT, false)
end

function mdns_if:send_delayed_multicast(p)
   local function is_query(p)
      return p.query
   end
   mst.d('send_delayed_multicast', #p)
   local q, r = mst.array_filter2(p, is_query)
   self:send_delayed_multicast_queries(q)
   self:send_delayed_multicast_replies(r)
end

function mdns_if:handle_multicast_probe(msg)
   self:d('got probe')

   -- XXX - this breaks MDNS idea somewhat, as we never defend
   -- something we claim is unique!

   -- zap _all_ conflicting records matching the entries being probed
   for i, rr in ipairs(msg.ns)
   do
      if rr.cache_flush
      then
         -- non-conflicting ones we don't need to care about!
         self.parent:stop_propagate_conflicting_rr(rr)
      end
   end
end

function mdns_if:msg_if_all_answers_known_and_unique(msg)
   local ns = self.own
   for i, q in ipairs(msg.qd)
   do
      local found = false
      iterate_ns_matching_query(ns, q, msg.an,
                                function (rr)
                                   if rr.cache_flush
                                   then
                                      found = true
                                   end
                                end)
      if not found then return false end
   end
   return true
end

function mdns_if:handle_multicast_query(msg, addr)
   -- consider if we know _all_ there is to know; that is, our 'own'
   -- set has responses to every query, and responses are cache_flush
   local delay
   if msg.h.tc
   then
      delay = mst.randint(400, 500)/1000.0
   elseif self:msg_if_all_answers_known_and_unique(msg)
   then
      -- make it possible to aggregate with others, but by default,
      -- send directly
      delay = 0
      -- another potential strategy - handle it directly
      -- XXX insert code for that
      --return
   else
      delay = mst.randint(20, 120)/1000.0
   end

   -- we can safely delay non-probe answers always
   -- (although it would be nice to be more defensive)
   local now = self.time()
   local when = now + delay
   local latest = when + 0.5
   self:d('queueing reply', now, when)
   self.pending:insert{when=when, latest=latest, addr=addr, msg=msg}
end

function mdns_if:update_rr_ttl(o, ttl, update_field)
   ttl = ttl or o.ttl
   self:a(ttl, 'no ttl?!?', o)
   o.ttl = ttl
   o.received_ttl = ttl
   -- we keep ttl's with zero received ttl of 0 for 1 second
   if ttl == 0
   then
      ttl = 1
   end
   o.time = self.time()
   o.valid = o.time + o.ttl
   o.valid_kas = o.time + o.ttl / 2
   if update_field
   then
      o[update_field] = o.time
   end
end

function mdns_if:handle_rr_cache_update(rr)
   local nsc = self.cache
   local old_rr = nsc:find_rr(rr)
   local o

   self:d('handle_rr_cache_update', rr, old_rr)

   if old_rr
   then
      if old_rr:equals(rr)
      then
         o = old_rr
      end
   end

   if not o
   then
      -- sanity check:

      -- if we received exactly same entry we've propagated on _some_
      -- interface, we just ignore it, unless it already exists in the
      -- cache for this particular interface
      
      -- (not o = not in cache for this interface)

      -- => now we do expensive check of checking through _all_ own
      -- entries for a match, and if found, we silently ignore this
      local found
      self.parent:iterate_ifs_rr('own', {name=rr.name,
                                         qtype=rr.rtype,
                                         rclass=rr.rclass},
                                 function (rr)
                                    found = true
                                 end, true, true)
      if found then return end
   end

   if rr.cache_flush
   then
      -- stop publishing potentially conflicting ones _everywhere_
      -- (= different from the 'rr' - 'rr' itself is ok)
      self.parent:stop_propagate_conflicting_rr(rr, self.ifname)
   end
   -- insert_rr if we don't have valid o yet
   if not o 
   then 
      -- if we didn't announce it, no need to start with 0 announce
      if rr.ttl == 0 then return end
      o = nsc:insert_rr(rr) 
      self:d('[cache] added RR', o)
   end

   -- update ttl fields of the received (and stored/updated) rr
   self:update_rr_ttl(o, rr.ttl, FIELD_RECEIVED)

   -- if information conflicts, don't propagate it
   -- (but instead remove everything we have)
   if self.parent:rr_has_conflicts(o)
   then
      -- if it wasn't cache_flush, get rid of the conflicting
      -- rr's
      if not o.cache_flush
      then
         self.parent:stop_propagate_conflicting_rr(o, self.ifname)
      end
      return
   end

   -- propagate the information (in some form) onwards
   self:d('propagating onward')
   self.parent:propagate_rr(o, self.ifname)
end

function mdns_if:handle_rr_list_cache_update(rrlist)
   if not rrlist or not #rrlist then return end
   for i, rr in ipairs(rrlist)
   do
      self:handle_rr_cache_update(rr)
   end
end

function mdns_if:handle_multicast_response(msg)
   self:d('got response')

   -- grab more information from an/ar - it's hopefully valid!
   self:handle_rr_list_cache_update(msg.an)
   self:handle_rr_list_cache_update(msg.ar)
end

function mdns_if:insert_own_rr(rr)
   local ns = self.own
   
   -- we don't accept NSEC records to be forwarded
   -- (we instead produce our own, see below)
   if rr.rtype == dns_const.TYPE_NSEC
   then
      return
   end

   -- XXX - do something with the old?
   --local old_rr = ns:find_rr(rr)
   if rr.ttl == 0
   then
      -- don't do a thing if it doesn't exist
      local o = ns:find_rr(rr)
      if not o
      then
         return 
      end
   end
   -- force copy - typically this is invoked on bunch of interfaces or
   -- whatever, and it makes life in general much more convenient
   local o, is_new = ns:insert_rr(rr, true)
   if is_new
   then
      if o.cache_flush
      then
         self:set_state(o, STATE_P1, self.p1_wu)
         self.p1_wu = o.wait_until
      else
         self:set_state(o, STATE_A1)
      end
      self:d('[own] added RR', o)
   end
   self:update_rr_ttl(o, rr.ttl)
   mst.a(o.valid, 'valid not set for own rr?!?')
   return o
end

function mdns_if:set_state(rr, st, wu)
   local w = STATE_DELAYS[st]
   self:d('setting state', rr, st)
   rr.state = st
   if w
   then
      local now = self.time()
      mst.a(type(now) == 'number', 'wierd time', now)
      if not wu
      then
         wu = now + mst.randint(w[1], w[2]) / 1000.0
      end
      rr.wait_until = wu
      return
   end
   -- no wait => should run it immediately
   self:run_state(rr)
end

function mdns_if:set_next_state(rr)
   -- may just go to next state too
   local next = NEXT_STATES[rr.state]
   if next ~= nil
   then
      if next
      then
         self:set_state(rr, next)
      else
         -- done!
         rr.state = nil
      end
   end
end

function mdns_if:run_state(rr)
   -- inherent wait (if any) is done; execute the state callback
   local state = rr.state
   local cb = STATE_CALLBACKS[state]
   if cb
   then
      cb(self, rr)
   end
   -- if something happened automatically, skip next-state mechanism
   if rr.state ~= state or rr.wait_until
   then
      return
   end
   self:set_next_state(rr)
end

function mdns_if:schedule_for_e_in_q(e, q)
   local latest = e.latest
   local best = e.when
   local query = e.query
   for e2, _ in pairs(q)
   do
      local when = e2.when
      if not e2.query == not query and when < latest and when > best
      then
         best = when
      end
   end
   return best
end

function mdns_if:next_time()
   local best, bestsrc
   function maybe(t, src)
      if not t then return end
      if not best or t < best
      then
         best = t
         bestsrc = src
      end
   end
   function update_cache(rr)
      maybe(rr.valid, 'cache expiration')
   end
   -- cache entries' expiration
   self.cache:foreach(update_cache)
   function update_own(rr)
      if rr.state
      then
         maybe(rr.wait_until, 'own expiration')
      end
      maybe(rr.valid, 'own valid')
   end
   self.own:foreach(update_own)
   local q = self.pending
   for e, _ in pairs(q)
   do
      local b = self:schedule_for_e_in_q(e, q)
      maybe(b, 'multicast')
   end
   if best
   then
      self:d('next_time', best, bestsrc)
   end
   return best
end

function mdns_if:send_announces()
   -- try to send _all_ eligible announcements at once.
   -- e.g. entries that are in one of the send-announce states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self.own
   local an 
   local now = self.time()

   -- the draft isn't very strict about how long we can delay until we
   -- announce; so what we do, is wait until _all_ messages in
   -- wait_until state disappear
   local waitmore = false
   ns:foreach(function (rr)
                 if announce_states[rr.state] 
                 then
                    if rr.wait_until
                    then
                       waitmore = rr.wait_until
                    else
                       -- xxx - do something more clever here?
                       an = an or {}
                       table.insert(an, rr)
                    end
                 end
              end)
   if waitmore 
   then 
      self:d('skipping announce - waiting for more at', waitmore)
      if an
      then
         for i, rr in ipairs(an)
         do
            rr.wait_until = waitmore
         end
      end
      return 
   end
   -- XXX ( handle fragmentation )
   if an
   then
      for i, rr in ipairs(an)
      do
         self:set_next_state(rr)
         rr[FIELD_SENT_MCAST] = now

         if rr.cache_flush
         then
            -- potentially update the nsec record
            self:update_rr_related_nsec(rr)
         end
      end
      local h = MDNS_DEFAULT_RESPONSE_HEADER
      local s = dnscodec.dns_message:encode{an=an, h=h}
      local dst = MDNS_MULTICAST_ADDRESS .. '%' .. self.ifname
      mst.d(now, 'sending announce(s)', #an)
      self.sendto(s, dst, MDNS_PORT)

   end
end

function mdns_if:update_rr_related_nsec(rr)
   local bits = {}
   local nsec
   local least
   local now = self.time()
   local ns = self.own

   for i, rr2 in ipairs(ns:find_rr_list_for_ll(rr.name))
   do
      if rr2.rtype == dns_const.TYPE_NSEC
      then
         nsec = rr2
      else
         table.insert(bits, rr2.rtype)
         if not least or (rr2.valid and least > rr2.valid)
         then
            least = rr2.valid
         end
      end
   end

   -- first off, if we don't have really valid ttl _at all_, we give
   -- up:
   if not least 
   then
      return 
   end

   -- then, if that one's ttl would be <1, it's also valid case to give up
   local ttl = math.floor(least - now)
   if ttl < 1
   then
      return
   end
   
   -- 4 cases in truth

   -- either we don't have nsec => create

   -- invalid bits => update bits
   -- invalid ttl => update ttl
   -- valid => all good => do nothing
   -- (we sort of combine the last 3 cases, as there's no harm in it)

   table.sort(bits)
   if not nsec
   then
      -- create new nsec, with the bits we have
      nsec = {name=rr.name, 
              rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_NSEC, 
              ttl=ttl, 
              cache_flush=true,

              -- NSEC rdata
              rdata_nsec={
                 ndn=rr.name,
                 bits=bits, 
              },
      }
      nsec = ns:insert_rr(nsec)
      self:d('[own] added NSEC RR', nsec)
   end
   nsec.rdata_nsec.bits = bits
   -- update the ttl => nsec rr will always have valid etc set
   self:update_rr_ttl(nsec, ttl)
end

function mdns_if:send_probes()
   -- try to send _all_ eligible probes at once.
   -- e.g. entries that are in one of the send-probe states (a1, a2),
   -- and their wait_until is not set, for that interface..
   local ns = self.own
   local qd 
   local ons
   local tns = dnsdb.ns:new{}
   ns:foreach(function (rr)
                 if probe_states[rr.state] and not rr.wait_until
                 then
                    local found = false
                    tns:iterate_rrs_for_ll(rr.name, function () found=true end)
                    if not found
                    then
                       qd = qd or {}
                       table.insert(qd, {qtype=dns_const.TYPE_ANY,
                                         qclass=rr.rclass,
                                         name=rr.name,
                                         qu=true})
                       tns:insert_rr(rr)
                    end
                    ons = ons or {}
                    table.insert(ons, rr)
                    self:set_next_state(rr)
                 end
              end)
   -- XXX ( handle fragmentation )
   if qd
   then
      -- clear the 'next send probe' time
      self.p1_wu = nil
      self:send_multicast_query(qd, nil, ons)
   end
end

function mdns_if:stop_propagate_rr_sub(rr, similar, equal)
   -- remove all matching _own_ rr's
   -- (we simply pretend rr doesn't exist at all)
   -- similar only, not equal(?)
   self.own:iterate_ns_rr(ns, rr,
                          function (rr2)
                             self:d('removing own', similar, equal, rr)
                             ns:remove_rr(rr2)
                          end, similar, equal)
end

function mdns_if:handle_recvfrom(data, addr, srcport)
   local msg = dnscodec.dns_message:decode(data)

   -- ok, if it comes from non-mdns port, life's simple
   if srcport ~= MDNS_PORT 
   then
      self:handle_unicast_query(msg, addr, srcport)
      return
   end

   -- ignore stuff with rcode set
   -- (XXX - should this check be done before or after qu?)
   if msg.h.rcode > 0
   then
      return
   end

   if msg_has_qu_qd(msg)
   then
      -- hybrid case; we may provide part of answer via unicast, and
      -- rest via multicast
      local qu, nqu = self:split_qd_to_qu_nqu(msg)
      self:d('split to #qu, #nqu', #qu, #nqu)
      if #qu > 0
      then
         local h = mst.table_copy(MDNS_DEFAULT_RESPONSE_HEADER)
         h.id=msg.h.id
         self:handle_unicast_query({qd=qu,
                                    h=h,
                                    an=msg.an},
                                   addr, srcport)
      end
      if #nqu == 0
      then
         return
      end
      msg.qd = nqu
   end

   -- we don't care about srcport, as it's shared from now on.  let's
   -- just pass along ifname from now on, and we should be good (addr,
   -- while interesting, is not really needed)

   -- ok. it's qm message, but question is, what is it?
   -- cases we want to distinguish:

   -- a) probe (qd=query, ns=authoritative)
   if msg.qd and #msg.qd>0
   then
      if msg.ns and #msg.ns>0
      then
         self:handle_multicast_probe(msg)
         return
      end

      -- b) query (qd=query set [rest we ignore])
      self:handle_multicast_query(msg, addr)
      return
   end

   -- c) response/announce (an=answer, ar=additional records)
   -- (announce is just unsolicited response)
   if msg.an and #msg.an>0
   then
      self:handle_multicast_response(msg)
      return
   end

end