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
-- Last modified: Fri Feb  1 00:17:57 2013 mstenber
-- Edit time:     412 min
--

-- For efficient storage, we have skiplist ordered on the 'time to
-- next action' of the items. The rr's are stored within 'cache' (what
-- we have received from the network on this interface), and 'own'
-- (what we publish to the network on this interface as authoritative)

-- ttna, or 'next' can be based on

-- ttl => expiration [cache, own]
-- 0,x * ttl => re-request item [cache only]
-- active state of the rr [own only]

-- what causes ttna to be updated:
-- - refresh of ttl [cache, own]
-- - adding/removing of active query that matches the rr [cache only]
-- - state change of the rr [own only]

-- The key here is to avoid (costly) iteration of the whole database,
-- if it's not really needed. 

require 'mst'
require 'dnscodec'
require 'dnsdb'
require 'mdns_const'
require 'mst_skiplist'

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
STATE_DELAYS={[STATE_P1]={1, 250},
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

local function extend_kas_with_anish(kas, l)
   if not l then return end
   for i, a in ipairs(l)
   do
      kas:insert_rr(a)
   end
end

local function convert_anish_to_kas(kas)
   if not kas then return end
   if dnsdb.ns:is_instance(kas) then return kas end
   -- on-the-fly convert list of answers to dnsdb:ns
   local tns = dnsdb.ns:new{}
   mst.a(type(kas) == 'table', 'weird kas', kas)
   extend_kas_with_anish(tns, kas)
   return tns
end

local function kas_matches_rr(kas, rr)
   if not kas then return end
   local orr = kas:find_rr(rr)
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

-- mdns for single interface; leveraged by mdns_core, and subclassable
-- if needed

-- per-if structure, which does most of the logic and has
-- per-structure data
mdns_if = mst.create_class{class='mdns_if',
                           mandatory={'ifname', 'parent'}}

function mdns_if:init()
   self.cache = dnsdb.ns:new{}

   self.own = dnsdb.ns:new{}

   -- set of queries/responses to be handled 'soon'
   -- (query has .query; response to message has .msg, among other things)
   self.pending = mst.set:new{}

   -- 1/10 percentage points, the offset we use to 80%
   -- when querying active records
   self.qofs = mst.randint(0, 20)

   function next_is_less(o1, o2)
      return o1.next < o2.next
   end
   self.cache_sl = mst_skiplist.ipi_skiplist:new{p=2,
                                                 prefix='cache_sl',
                                                 lt=next_is_less,
                                                }
   function self.cache.removed_callback(x, rr)
      self.cache_sl:remove_if_present(rr)
   end
                            
   self.own_sl = mst_skiplist.ipi_skiplist:new{p=2,
                                               prefix='own_sl',
                                               lt=next_is_less,
                                              }
   function self.own.inserted_callback(x, rr)
      if rr.cache_flush
      then
         self:update_rr_related_nsec(rr)
      end
   end
   function self.own.removed_callback(x, rr)
      self.own_sl:remove_if_present(rr)
      if rr.cache_flush
      then
         self:update_rr_related_nsec(rr)
      end
   end
end

function mdns_if:sendto(...)
   self.parent.sendto(...)
end

function mdns_if:time()
   -- if parent contains already now, we use that
   local now = self.parent.now
   if now then return now end
   return self.parent.time()
end

function mdns_if:repr_data()
   return self.ifname
end

function mdns_if:run_own_states()
   local now = self:time()
   mst.a(type(now) == 'number', now)
   local ns = self.own
   local pending
   self.own_sl:iterate_while(function (rr)
                                if rr.next > now 
                                then
                                   --self:d('too late', rr)
                                   return
                                end
                                if rr.state 
                                   and rr.wait_until and rr.wait_until <= now
                                then
                                   self:d('picking to run', rr)
                                   -- stateful waiting is handled here
                                   -- (expire handles non-stateful)
                                   self.own_sl:remove(rr)
                                   rr.wait_until = nil
                                   pending = pending or mst.map:new{}
                                   pending[rr] = rr.state
                                end
                                return true
                             end)
   if pending
   then
      mst.d('running pending states', pending:count())
      for rr, state in pairs(pending)
      do
         if rr.state == state
         then
            self:run_state(rr)
            -- make sure no matter what, rr's stay in own_sl
            -- (if it's relevant)
            self.own_sl:insert_if_not_present(rr)
         end
      end
   end
   return pending
end


function mdns_if:run_expire()
   local pending
   local now = self:time()

   -- get rid of own rr's that have expired
   self.own_sl:iterate_while(function (rr)
                                if rr.next > now 
                                then
                                   return
                                end
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
                                return true
                             end)

   -- get rid of cache rr's that have expired
   self.cache_sl:iterate_while(function (rr)
                                  -- first off, see if it's worth
                                  -- iterating anymore
                                  if rr.next > now
                                  then
                                     return
                                  end
                                  if rr.valid > now
                                  then
                                     self:query_cache_rr_perhaps(rr)
                                     return true
                                  end
                                  self:d('[cache] getting rid of', rr)
                                  self:expire_cache_rr(rr)
                                  self.cache:remove_rr(rr)
                                  return true
                               end)
   if pending
   then
      self:d('sending expire ttl=0 for #pending', #pending)
      -- send per-interface 'these are gone' fyi messages
      local s = dnscodec.dns_message:encode{an=pending, 
                                            h=mdns_const.DEFAULT_RESPONSE_HEADER}
      local dst = mdns_const.MULTICAST_ADDRESS_IPV6 .. '%' .. self.ifname
      self:sendto(s, dst, mdns_const.PORT)
   end
end

function mdns_if:run_send_pending()
   local pending
   local q = self.pending
   local now = self:time()

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
   while self:run_own_states() do end
   
   -- expire old records
   self:run_expire()

   -- send delayed multicast queries and responses
   self:run_send_pending()
end

function mdns_if:split_qd_to_qu_nqu(msg)
   local qu = {}
   local nqu = {}
   local now = self:time()
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

function mdns_if:get_own_nsec_rr_current_ttl(rr, now)
   local least
   local ns = self.own
   for i, rr2 in ipairs(ns:find_rr_list_for_ll(rr.name))
   do
      if rr2.rtype ~= dns_const.TYPE_NSEC
      then
         local ttl = self:get_own_rr_current_ttl(rr2, now)
         self:a(ttl, 'no ttl for rr', rr2)
         if not least or least > ttl
         then
            least = ttl
         end
      end
   end
   -- nsec should exist only as long as other rr's do; therefore,
   -- if it still exists, but nothing else does, things have gone ..
   -- wrong.
   self:a(least, 'no ttl found?!?')
   return least
end

function mdns_if:get_own_rr_current_ttl(rr, now)
   if rr.rtype == dns_const.TYPE_NSEC
   then
      return self:get_own_nsec_rr_current_ttl(rr, now)
   end
   if not rr.valid
   then
      -- we do stuff based on the defaults for the rtype
      local v = (dns_rdata.rtype_map[rr.rtype] or {}).default_ttl 
         or mdns_const.DEFAULT_NONAME_TTL
      return v
   end
   local now = now or self:time()
   local ttl = math.floor(rr.valid-now)
   return ttl
end

function mdns_if:copy_rrs_with_updated_ttl(rrl, unicast, legacy)
   local now = self:time()
   local r = {}
   for i, rr in ipairs(rrl)
   do
      local ttl = self:get_own_rr_current_ttl(rr, now)
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
         if legacy
         then
            n.cache_flush = false
         end
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
         local cand = {name=a.name, rtype=t2, rclass=a.rclass}
         if a.rtype == t1 
            and not all:find_rr(cand)
            and not kas_matches_rr(kas, cand)
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

function mdns_if:send_reply(an, ar, kas, id, dst, dstport, unicast)
   -- ok, here we finally reduce duplicates, update ttl's, etc.
   local legacy = dstport ~= mdns_const.PORT

   mst.d('send_reply', an, kas, id, dst, dstport, unicast, legacy)

   an = self:copy_rrs_with_updated_ttl(an, unicast, legacy)
   if #an == 0 then return end

   -- we also determine additional records
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
   self:sendto(s, dst, dstport)

end

function mdns_if:send_multicast_query(qd, kas, ns)
   local dst = mdns_const.MULTICAST_ADDRESS_IPV6 .. '%' .. self.ifname
   local an
   if kas
   then
      local oan = kas:values()
      -- pretend to be unicast - we don't want the sent timestamps
      -- disturbed by stuff that doesn't update neighbor caches

      -- also pretend to be legacy - according to section 10 of the
      -- draft, cache flush should not be set 
      an = self:copy_rrs_with_updated_ttl(oan, true, true)
      mst.d('kas ttl update', #oan, #an)
   end
   local s = dnscodec.dns_message:encode{qd=qd, an=an, ns=ns}
   self:sendto(s, dst, mdns_const.PORT)
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
   local ar = self:determine_ar(an, kas)
   self:send_reply(an, ar, kas, msg.h.id, src, srcport, true)
end

function mdns_if:find_pending_with_query(q)
   for e, _ in pairs(self.pending)
   do
      if e.query and match_q_q(e.query, q)
      then
         return e
      end
   end
end

function mdns_if:query(q, rep)
   -- first off, if we have already this scheduled, forget about it
   if not rep
   then
      if self:find_pending_with_query(q)
      then
         return
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
   local now = self:time()
   local when = now + delay
   local latest = when + 0.5
   mst.d(now, 'adding query', when, latest, q, rep)
   self.pending:insert{when=when, latest=latest, query=q, rep=rep}
end

function mdns_if:start_query(q)
   self:query(q, true)
end

function mdns_if:stop_query(q)
   local e = self:find_pending_with_query(q)
   if e
   then
      self:d('removing query', e)
      self.pending:remove(e)
      return
   end
   self:d('no query to be removed', q)
end

function mdns_if:send_delayed_multicast_queries(ql)
   if #ql == 0 then return end
   local qd = mst.array:new{}
   local ns = self.own
   local nsc = self.cache
   local kas = dnsdb.ns:new{}
   local now = self:time()

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

   -- what we do, is go through the queries, and answer to anything
   -- not on kas of that particular query (or answered with one of the
   -- earlier queries). 
   local kas 
   local full_an = mst.set:new{}
   local full_ar = mst.set:new{}

   function _extend_set(s, l)
      for i, v in ipairs(l)
      do
         s:insert(v)
      end
   end

   for i, e in ipairs(q)
   do
      local msg = e.msg
      kas = convert_anish_to_kas(msg.an)
      local an = self:find_own_matching_queries(msg.qd, kas)
      _extend_set(full_an, an)

      local ar = self:determine_ar(an, kas)
      _extend_set(full_ar, ar)
   end

   -- remove from ar what's in an
   full_ar = full_ar:difference(full_an)

   -- and send the reply
   local dst = mdns_const.MULTICAST_ADDRESS_IPV6 .. '%' .. self.ifname
   self:send_reply(full_an:keys(), full_ar:keys(), 
                   nil, 0, dst, mdns_const.PORT, false)
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
         self:stop_propagate_conflicting_rr(rr)
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

   self:d('handle_multicast_query', msg, addr)
   -- aggregate earlier qd, an fields together in hte pending queue
   if addr
   then
      for e, _ in pairs(self.pending)
      do
         --and e.msg.id == msg.id
         -- should be 0 in both, not worth checking
         if e.msg and e.addr == addr 
         then
            self:d(' aggregating', e)
            msg.qd:extend(e.msg.qd)
            msg.an:extend(e.msg.an)
            self.pending:remove(e)
         end
      end
   end

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
   local now = self:time()
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
   o.time = self:time()
   o.valid = o.time + o.ttl
   o.valid_kas = o.time + o.ttl / 2
   if update_field
   then
      o[update_field] = o.time
   end
end

function mdns_if:upsert_cache_rr(rr)
   local nsc = self.cache
   local old_rr = nsc:find_rr(rr)
   local o

   self:d('upsert_cache_rr', rr, old_rr)

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

      local found

      -- two cases

      -- in own of same interface
      local q = {name=rr.name,
                 qtype=rr.rtype,
                 qclass=rr.rclass}

      iterate_ns_matching_query(self.own, q, nil,
                                function (rr2)
                                   if rr2:equals(rr)
                                   then
                                      found = true
                                      local ttl = self:get_own_rr_current_ttl(rr2)
                                      if ttl >= (rr.ttl * 2)
                                      then
                                         -- pretend to have received
                                         -- query for it => matching stuff
                                         -- will be re-broadcast shortly
                                         local fmsg = {h={},qd={q}}
                                         self:handle_multicast_query(fmsg)
                                      end
                                   end
                                end)
      if found then return end

      -- in some other interface (loop in network topology?)
      -- => now we do expensive check of checking through _all_ own
      -- entries for a match, and if found, we silently ignore this

      self.parent:iterate_ifs_ns_matching_q('own', q,
                                            function (rr2)
                                               if rr2:equals(rr)
                                               then
                                                  found = true
                                               end
                                            end)
      if found then return end
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
   
   -- remove/insert it from cached skiplist
   self:update_next_cached(o)

   -- if information conflicts, don't propagate it
   -- (but instead remove everything we have)
   if self:rr_has_cache_conflicts(o)
   then
      self:stop_propagate_conflicting_rr(o)
      return
   end

   -- propagate the information (in some form) onwards
   self:d('propagating onward')
   self:propagate_rr(o)
end

local function update_sl_if_changed(sl, o, v)
   if o.next == v
   then
      return
   end
   sl:remove_if_present(o)
   o.next = v
   if v
   then
      sl:insert(o)
   end
end

function mdns_if:update_next_cached(o)
   local v = o.valid
   -- I _wish_ it was this simple. However, we need to keep track of
   -- retries, and the real count is
   -- 80% + self.qofs/10 % + retries * 5
   -- (if 4 retries done, use full valid)
   local r = o.queries or 0
   if r < 4
   then
      -- have to send a query.. figure when
      -- (or, at least, actively choose _not_ to send query)
      local delta = (o.valid - o.time) * (800 + self.qofs + 50 * r) / 1000
      v = o.time + delta
   end
   update_sl_if_changed(self.cache_sl, o, v)
end

function mdns_if:query_cache_rr_perhaps(rr)
   -- update query # 
   local r = rr.queries or 0
   -- we should be called with rr.queries of 0-3; 
   -- 4 is an error (it would happen at 100-102% of ttl)
   self:a(r < 4, 'too many queries')
   rr.queries = r + 1
   self:update_next_cached(rr)

   local q = self:interested_in_cached(rr)
   if q
   then
      -- schedule a query for the rr
      self:query(q)
   else
      self:d('nobody interested about', rr)
   end
end

function mdns_if:update_next_own(o)
   local v1 = o.wait_until
   local v2 = o.valid
   if v1 and (not v2 or v1 < v2)
   then
      update_sl_if_changed(self.own_sl, o, v1)
   else
      update_sl_if_changed(self.own_sl, o, v2)
   end
end


function mdns_if:upsert_cache_rrs(rrlist)
   if not rrlist or not #rrlist then return end
   -- initially, get rid of the conflicting ones based on
   -- cache_flush being set; due to this, we insert whole set's
   -- worth of cache_flushed entries at once, later..
   local todo = {}
   local ns = self.own
   local nsc = self.cache
   for i, rr in ipairs(rrlist)
   do
      if rr.cache_flush
      then
         -- stop publishing potentially conflicting ones _everywhere_
         self:stop_propagate_conflicting_rr(rr, true)
      end
      if rr.ttl == 0 and not nsc:find_rr(rr) and not ns:find_rr(rr)
      then
         -- skip
      else
         table.insert(todo, rr)
      end
   end
   for i, rr in ipairs(todo)
   do
      self:upsert_cache_rr(rr)
   end
end

function mdns_if:handle_multicast_response(msg)
   self:d('got response')

   -- grab more information from an/ar - it's hopefully valid!

   -- have to copy lists, as we want to handle this list in one
   -- transaction to handle rrsets correctly across an AND ar
   local t = {}
   mst.array_extend(t, msg.an)
   mst.array_extend(t, msg.ar)
   self:upsert_cache_rrs(t)
end

function mdns_if:insert_own_rrset(l)
   local ns = self.own

   local todo = {}

   for i, rr in ipairs(l)
   do
      local process
      -- we don't accept NSEC records to be forwarded
      -- (we instead produce our own, see below)
      if rr.rtype == dns_const.TYPE_NSEC
      then
         -- nop
      elseif rr.ttl == 0
      then
         local o = ns:find_rr(rr)
         if not o
         then
            -- don't do a thing if it doesn't exist
         else
            -- rr exists => play with it
            process = true
         end
      else
         -- not exception -> by default, we want to do something
         process = true
      end
      if process
      then
         table.insert(todo, rr)
      end
   end

   -- force copy - typically this is invoked on bunch of interfaces or
   -- whatever, and it makes life in general much more convenient
   local all, fresh = ns:insert_rrs(todo, true)
   for rr, o in pairs(fresh)
   do
      -- clear out the membership information (could have been in cache)
      self.cache_sl:clear_object_fields(o)

      if o.cache_flush
      then
         self:set_state(o, STATE_P1, self.p1_wu)
         self.p1_wu = o.wait_until
      else
         self:set_state(o, STATE_A1)
      end
      self:d('[own] added RR', o)
   end

   for rr, o in pairs(all)
   do
      if rr.ttl
      then
         self:update_rr_ttl(o, rr.ttl)
      end

      -- remove/insert it from own skiplist
      self:update_next_own(o)

      if rr.ttl
      then
         mst.a(o.valid, 'valid not set for own w/ ttlrr?!?')
      else
         mst.a(not o.valid, 'valid set for own rr w/o ttl?!?')
      end
   end
end


function mdns_if:insert_own_rr(rr)
   self:insert_own_rrset{rr}
end

function mdns_if:set_state(rr, st, wu)
   local w = STATE_DELAYS[st]
   self:d('setting state', rr, st)
   rr.state = st
   if w
   then
      local now = self:time()
      mst.a(type(now) == 'number', 'wierd time', now)
      if not wu
      then
         wu = now + mst.randint(w[1], w[2]) / 1000.0
      end
      rr.wait_until = wu
      self:update_next_own(rr)
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
   self:d('looking for next_time', self.cache_sl, self.own_sl, #self.pending)
   -- cache entries' expiration
   local o = self.cache_sl:get_first()
   if o
   then
      maybe(o.valid, 'cache valid')
   end
   local o = self.own_sl:get_first()
   if o
   then
      maybe(o.valid, 'own valid')
      maybe(o.wait_until, 'own wait_until')
   end
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
   local now = self:time()

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
            self:update_next_own(rr)
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
      end
      local h = mdns_const.DEFAULT_RESPONSE_HEADER
      local s = dnscodec.dns_message:encode{an=an, h=h}
      local dst = mdns_const.MULTICAST_ADDRESS_IPV6 .. '%' .. self.ifname
      mst.d(now, 'sending announce(s)', #an)
      self:sendto(s, dst, mdns_const.PORT)
   end
end

function mdns_if:update_rr_related_nsec(rr)
   local bits = {}
   local nsec
   local now = self:time()
   local ns = self.own

   for i, rr2 in ipairs(ns:find_rr_list_for_ll(rr.name))
   do
      if rr2.rtype == dns_const.TYPE_NSEC
      then
         nsec = rr2
      else
         table.insert(bits, rr2.rtype)
      end
   end

   -- if nothing else exists, we want just to get rid of nsec, if any
   if #bits == 0
   then
      -- remove nsec, if any, too
      if nsec
      then
         ns:remove_rr(nsec)
      end
      return 
   end

   -- 4 cases in truth

   -- either we don't have nsec => create

   -- invalid bits => update bits
   -- valid => all good => do nothing
   -- (we sort of combine the last 3 cases, as there's no harm in it)

   table.sort(bits)
   if not nsec
   then
      -- create new nsec, with the bits we have
      nsec = {name=rr.name, 
              rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_NSEC, 
              cache_flush=true,

              -- NSEC rdata
              rdata_nsec={
                 ndn=rr.name,
                 bits=bits, 
              },
      }
      nsec = ns:insert_rr(nsec)
      self:d('[own] added NSEC RR', nsec)
   else
      nsec.rdata_nsec.bits = bits
      -- XXX - should we proactively send updated nsec record if bits
      -- have changed?
   end
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
      mst.d('sending probes', #qd)

      -- clear the 'next send probe' time
      self.p1_wu = nil
      self:send_multicast_query(qd, nil, ons)
   end
end

function mdns_if:stop_propagate_rr(rr)
   local ns = self.own
   
   -- stop propagation of this specific rr on this interface => has to
   -- be exact match, in own
   local orr = ns:find_rr(rr)
   if not orr then return end

   ns:remove_rr(orr)
   self.own_sl:remove_if_present(orr)
end

function mdns_if:handle_recvfrom(data, addr, srcport)
   local msg = dnscodec.dns_message:decode(data)

   -- ok, if it comes from non-mdns port, life's simple
   if tonumber(srcport) ~= mdns_const.PORT 
   then
      if msg.qd and #msg.qd > 0
      then
         self:handle_unicast_query(msg, addr, srcport)
         return
      end
      -- MUST accept unicast responses if they answer
      -- recently-sent query => as we never query over unicast, we NEVER
      -- accept unicast responses
      self:d('spurious unicast response', srcport)
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
         local h = mst.table_copy(mdns_const.DEFAULT_RESPONSE_HEADER)
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

   -- different query variants
   if not msg.h.qr
   then
      -- a) probe (qd=query, ns=authoritative)
      if msg.ns and #msg.ns>0
      then
         self:handle_multicast_probe(msg)
         return
      end

      -- b) query (qd=query set [rest we ignore] perhaps, an=kas)
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

-- subclassable functionality

-- do we have 'active client interest' in this specific rr?
-- subclasses can obviously override this
function mdns_if:interested_in_cached(rr)
   for e, _ in pairs(self.pending)
   do
      local q = e.query
      if q and match_q_rr(q, rr)
      then
         self:d('found interested query in us', q, rr)
         -- (very specific one, sigh.. would it not be more efficient
         -- just to ask for 'all'?)
         return {name=q.name,
                 qtype=rr.rtype,
                 qclass=rr.rclass}
      end
   end
end

function mdns_if:propagate_rr(rr)
   self.parent:propagate_if_rr(self.ifname, rr)
end

function mdns_if:expire_cache_rr(rr)
   self.parent:expire_if_cache_rr(self.ifname, rr)
end

function mdns_if:start_expire_own_rr(rr)
   mst.d('start_expire_own_rr', rr)

   -- start ttl=0 process for the rr, and process it on next event
   self:update_rr_ttl(rr, 0)
   
   -- remove/insert it from own skiplist
   self:update_next_own(rr)
end

function mdns_if:stop_propagate_conflicting_rr_sub(rr, clear_rrset)
   if not clear_rrset
   then
      -- see if it exists within the rr - if it does, no
      -- need to zap anything
      if self.own:find_rr(rr)
      then
         return
      end
   end

   -- find similar rr's that are not equal to this rr
   self.own:iterate_rrs_for_ll(rr.name,
                               function (rr2)
                                  -- if exactly same, skip
                                  self:d('[conflict] removing own', rr2)
                                  self:stop_propagate_rr(rr2)
                               end)
end



function mdns_if:stop_propagate_conflicting_rr(rr, clear_rrset)
   self.parent:stop_propagate_conflicting_if_rr(self.ifname, rr, clear_rrset)
end

function mdns_if:rr_has_cache_conflicts(rr)
   return self.parent:if_rr_has_cache_conflicts(self.ifname, rr)
end
