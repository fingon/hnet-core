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
-- Last modified: Mon Apr 29 11:08:58 2013 mstenber
-- Edit time:     761 min
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
require 'dns_codec'
require 'dns_db'
require 'mdns_const'
require 'mst_skiplist'
require 'mdns_discovery'

module(..., package.seeall)

-- Ignore the TTL values below this; the TTL due to clock differences
-- can skew a bit, and lead to unneccessary network churn if we
-- e.g. re-broadcast TTL below 5
IGNORE_TTL_BELOW=5

-- probing states (waiting to send message N)
STATE_P1='p1'
STATE_P2='p2'
STATE_P3='p3'
STATE_PW='pw'
-- => a1 if no replies

-- forcibly send probes every <this period>, even if there are more pending
SEND_PROBES_EVERY=0.3

-- forcibly send announces every <this period>, even if there are more pending
SEND_ANNOUNCES_EVERY=1.2

-- how often can RR be sent on link (probe overrides this)
MINIMAL_RR_SEND_INTERVAL=1

-- how long we maintain idea about what others are probing for
KEEP_PROBES_FOR=1

-- waiting to start probe again
-- STATE_WP1='wp1' 
-- as we treat failed probes 'definitely not our problem', there isn't
-- conflict here.. :-p

-- announce states - waiting to announce (based on spam-the-link frequency)
STATE_A1='a1'
STATE_A2='a2'

-- when do we call the 'run' method for a state after we have entered the state?
STATE_DELAYS={[STATE_P1]={1, 250},
              [STATE_P2]={250, 250},
              [STATE_P3]={250, 250},
              [STATE_PW]={250, 250},
              --[STATE_WP1]={1000, 1000},
              [STATE_A1]={20, 120},
              [STATE_A2]={1000, 1000},
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

function q_for_q(oq, q)
   q = q or {}
   q.name = q.name or oq.name
   q.qtype = q.qtype or oq.qtype
   q.qclass = q.qclass or oq.qclass
   -- sanity check - this shouldn't happen in production code, hopefully
   --mst.a(q.qclass == dns_const.CLASS_IN or q.qclass == dns_const.CLASS_ANY)
   return q
end

function q_for_rr(rr, q)
   q = q or {}
   q.name = q.name or rr.name
   q.qtype = q.qtype or rr.rtype
   q.qclass = q.qclass or rr.rclass
   -- sanity check - this shouldn't happen in production code, hopefully
   --mst.a(q.qclass == dns_const.CLASS_IN or q.qclass == dns_const.CLASS_ANY)
   return q
end

local function match_q_rr(q, rr)
   return (q.qtype == dns_const.TYPE_ANY or q.qtype == rr.rtype) 
      and (q.qclass == dns_const.CLASS_ANY or q.qclass == rr.rclass) 
      and dns_db.ll_equal(q.name, rr.name)
end

local function match_q_q(q, o)
   return q.qtype == o.qtype 
      and q.qclass == o.qclass
      and dns_db.ll_equal(q.name, o.name)
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
   if dns_db.ns:is_instance(kas) then return kas end
   -- on-the-fly convert list of answers to dns_db:ns
   local tns = dns_db.ns:new{}
   mst.a(type(kas) == 'table', 'weird kas', kas)
   extend_kas_with_anish(tns, kas)
   return tns
end

-- mdns for single interface; leveraged by mdns_core, and subclassable
-- if needed

-- per-if structure, which does most of the logic and has
-- per-structure data
mdns_if = mst.create_class{class='mdns_if',
                           mandatory={'ifname', 'parent'}}

function mdns_if:init()
   self.cache = dns_db.ns:new{}

   self.own = dns_db.ns:new{}

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
   function self.cache.inserted_callback(x, rr)
      self:cache_changed_rr(rr, true)
   end
   function self.cache.removed_callback(x, rr)
      self.cache_sl:remove_if_present(rr)
      self:cache_changed_rr(rr, false)
   end
   
   self.own_sl = mst_skiplist.ipi_skiplist:new{p=2,
                                               prefix='own_sl',
                                               lt=next_is_less,
                                              }

   function self.own.inserted_callback(x, rr)
      if rr.cache_flush
      then
         self:mark_nsec_dirty(rr)
      end
   end
   function self.own.removed_callback(x, rr)
      self.own_sl:remove_if_present(rr)
      if rr.cache_flush
      then
         self:mark_nsec_dirty(rr)
      end
   end

   self.probe = dns_db.ns:new{}
   self.probe_sl = mst_skiplist.ipi_skiplist:new{p=2,
                                                 prefix='probe_sl',
                                                 lt=next_is_less,
                                                }

   self.md = mdns_discovery.mdns_discovery:new{
      time=function ()
         return self:time()
      end,
      query=function (q)
         return self:query(q)
      end,
                                              }
end

function mdns_if:cache_changed_rr(rr, mode)
   -- parent doesn't really need to know
   --self.parent:cache_changed_if_rr(self.ifname, rr, mode)

   -- anything else than the fact taht rr state for this entry may be
   -- suspicious
   self.parent:queue_check_propagate_if_rr(self.ifname, rr)

   self.md:cache_changed_rr(rr, mode)
end

function mdns_if:kas_matches_rr(is_own, kas, rr)
   if not kas then return end
   local orr = kas:find_rr(rr)
   if not orr then return end

   -- ({o,}rr.ttl can be nil, if it's from our own OSPF source, for
   -- example; it is clearly still valid match as it has 'infinite'
   -- lifetime)

   -- if not set in kas, we pretend ttl is valid
   local ttl_kas = orr.ttl
   if not ttl_kas then return true end

   local ttl_rr 
   if is_own
   then
      ttl_rr = self:get_own_rr_current_ttl(rr)
   else
      ttl_rr = self:get_cache_rr_current_ttl(rr)
   end

   -- rr = propsed answer
   -- orr = what we got in KAS
   local r = ttl_kas >= ttl_rr / 2
   mst.d('kas_matches_rr - ttl check', r, orr.ttl, rr.ttl)
   return r
end

function mdns_if:iterate_matching_query(is_own, q, kas, f)
   local ns = is_own and self.own or self.cache
   local matched
   local found_cf

   mst.a(type(q) == 'table', 'weird q', q)
   kas = convert_anish_to_kas(kas)
   self:d('iterate_matching_query', ns, kas)

   for i, rr in ipairs(ns:find_rr_list_for_ll(q.name))
   do
      if rr.cache_flush
      then
         found_cf = true
      end
      if match_q_rr(q, rr)
      then  
         matched = true
         if not self:kas_matches_rr(is_own, kas, rr)
         then
            mst.d(' calling callback', rr)
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
      self:iterate_matching_query(is_own, 
                                  q_for_q(q, {qtype=dns_const.TYPE_NSEC}),
                                  kas, f)
   end
end

function mdns_if:mark_nsec_dirty(rr)
   local d = self.dirty_nsec
   if not d
   then
      d = dns_db.ns:new{}
      self.dirty_nsec = d
   end
   d:insert_rr{name=rr.name, rtype=0,rclass=0}
end

function mdns_if:refresh_dirty_nsecs()
   local d = self.dirty_nsec
   if not d then return end
   self.dirty_nsec = nil
   -- non-safe version is ok, as we don't mutate d, but self instead
   d:iterate_rrs(function (rr)
                    self:update_rr_related_nsec(rr)
                 end)
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

function mdns_if:run_own_states(now)
   -- stateful waiting is handled here
   -- (expire handles non-stateful)
   self:a(type(now) == 'number', now)
   local ns = self.own
   local pending
   self.own_sl:iterate_while(function (rr)
                                if rr.next > now 
                                then
                                   self:d('too late', now, rr)
                                   return
                                end
                                if rr.wait_until and rr.wait_until <= now
                                then
                                   self:a(rr.state, 'no state yet wait_until')
                                   self:d('picking to run', rr)

                                   pending = pending or mst.map:new{}
                                   pending[rr] = rr.state
                                end
                                return true
                             end)
   if pending
   then
      self:d('running pending states', pending:count())
      -- initially, clear wait_until of _all_ pending entries we
      -- picked (not done during iterate_while to avoid breaking skiplist)
      for rr, state in pairs(pending)
      do
         rr.wait_until = nil
         self:update_next_own(rr)
      end
      -- then, as long as states are as expected, call run_state for them
      for rr, state in pairs(pending)
      do
         if rr.state == state
         then
            self:run_state(rr)
         end
      end
   end
   return pending
end


function mdns_if:run_expire(now)
   self:a(type(now) == 'number', now)

   local pending

   -- get rid of own rr's that have expired
   self.own_sl:iterate_while(function (rr)
                                if rr.next > now 
                                then
                                   self:d('too late', now, rr)
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
                                  self.cache:remove_rr(rr)
                                  return true
                               end)
   if pending
   then
      self:d('sending expire ttl=0 for #pending', #pending)
      -- send per-interface 'these are gone' fyi messages
      local s = dns_codec.dns_message:encode{an=pending, 
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
   -- get current timestamp
   local now = self:time()

   -- call discovery run
   if not self.parent.disable_discovery
   then
      self.md:run()
   end

   -- get rid of old probes if any
   self:prune_probes()

   -- clear up the dirty nsec entries, if any, that are around
   -- as result of 'other' processing
   self:refresh_dirty_nsecs()

   -- iteratively run through the object states until all are waiting
   -- for some future timestamp
   while self:run_own_states(now) do end
   
   -- expire old records
   self:run_expire(now)

   -- check nsecs again - expire/own state running may have altered
   -- the state we want to present to the world
   self:refresh_dirty_nsecs()

   -- send delayed multicast queries and responses
   self:run_send_pending()

   -- semi-interesting check, but like elsewhere, probably not
   -- applicable always; therefore, should be skipped
   -- ( see e.g. update_sl_if_changed )

   --local nt = self:next_time()
   --self:a(not nt or nt >= now, 
   --'if we just did RTC step, why do we want to move to past?', now, nt)
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
      self:iterate_matching_query(true, q, msg.an,
                                  function (rr)
                                     local last = rr[FIELD_SENT_MCAST]
                                     local ttl = self:get_rr_full_ttl(rr)
                                     if not last or last < (now-ttl/4)
                                     then
                                        found = true
                                     end
                                  end)
      -- if found - pretend it's nqu
      return not found
   end
   return mst.array_filter2(msg.qd, is_qu)
end

function mdns_if:get_rr_full_ttl(rr)
   if rr.ttl
   then
      return rr.ttl
   end
   -- otherwise, default to type
   local v = (dns_rdata.rtype_map[rr.rtype] or {}).default_ttl 
      or mdns_const.DEFAULT_NONAME_TTL
   self:a(v, 'empty ttl somehow is not possible')
   return v
end

function mdns_if:find_own_matching_queries(ql, an)
   local r = mst.set:new{}
   local kas = convert_anish_to_kas(an)
   for i, q in ipairs(ql)
   do
      self:iterate_matching_query(true, q, kas, 
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
         if not least or (ttl and least > ttl)
         then
            least = ttl
         end
      end
   end
   -- nsec should exist only as long as other rr's do; therefore,
   -- if it still exists, but nothing else does, things have gone ..
   -- wrong. 

   -- pretend it is at ttl 0, as this is possible now that
   -- the nsec calculation is handled via 'dirty' mechanism, and
   -- not in quite real time.
   least = least or 0

   return least
end

function mdns_if:get_rr_current_ttl(rr, now)
   if rr.is_own
   then
      return self:get_own_rr_current_ttl(rr, now)
   else
      return self:get_cache_rr_current_ttl(rr, now)
   end
end

function mdns_if:get_own_rr_current_ttl(rr, now)
   self:a(rr.is_own == true)
   if rr.rtype == dns_const.TYPE_NSEC
   then
      return self:get_own_nsec_rr_current_ttl(rr, now)
   end
   -- if we received(/sent) 0, it means 0, regardless of validity
   if rr.ttl and rr.ttl < IGNORE_TTL_BELOW
   then
      return 0
   end
   if not rr.valid
   then
      return self:get_rr_full_ttl(rr)
   end
   return self:get_valid_rr_current_ttl(rr, now)
end

function mdns_if:get_cache_rr_current_ttl(rr, now)
   self:a(not rr.is_own)
   self:a(rr.valid, 'entries in cache MUST have valid set (and therefore also set ttl)')
   return self:get_valid_rr_current_ttl(rr, now)
end

function mdns_if:get_valid_rr_current_ttl(rr, now)
   local now = now or self:time()
   local ttl = math.floor(rr.valid-now)
   return ttl
end

function mdns_if:copy_rrs_with_updated_ttl(rrl, unicast, legacy, force)
   local r = {}
   local now = self:time()
   local invalid_since = (now - MINIMAL_RR_SEND_INTERVAL)
   for i, rr in ipairs(rrl)
   do
      local ttl = self:get_rr_current_ttl(rr, now)
      if not unicast 
      then
         if rr[FIELD_SENT_MCAST] and rr[FIELD_SENT_MCAST] > invalid_since and not force
         then
            --self:d('omitting - too recently sent', rr)
            ttl = 0
         elseif rr[FIELD_RECEIVED] and rr[FIELD_RECEIVED] > invalid_since and not force
         then
            --self:d('omitting - too recently received', rr)
            ttl = 0
         elseif ttl > 0
         then
            -- mark it sent
            rr[FIELD_SENT_MCAST] = now
         else
            --self:d('invalid ttl?', rr, ttl)
         end
      else
         self:d('unicast entry', ttl, rr)
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
   local all = dns_db.ns:new{}

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
            and not self:kas_matches_rr(true, kas, cand)
         then
            -- if we have something like this, cool, let's add it
            self:iterate_matching_query(true,
                                        q_for_rr(a, {qtype=t2}),
                                        kas,
                                        function (rr)
                                           if not all:find_rr(rr) 
                                              and not self:kas_matches_rr(true, kas, rr)
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

   self:d('send_reply', an, kas, id, dst, dstport, unicast, legacy)

   an = self:copy_rrs_with_updated_ttl(an, unicast, legacy)
   if #an == 0 then return end

   -- we also determine additional records
   ar = self:copy_rrs_with_updated_ttl(ar, unicast, legacy)

   -- ok, we have valid things to send with >0 ttl; here we go!
   local o = {an=an, ar=ar}
   local h = {}
   o.h = h

   h.id = id
   h.qr = true
   h.aa = true

   local s = dns_codec.dns_message:encode(o)
   self:d('sending reply', o)
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
      self:d('kas ttl update', #oan, #an)
   end
   local s = dns_codec.dns_message:encode{qd=qd, an=an, ns=ns}
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
   self:d(now, 'adding query', when, latest, q, rep)
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
   local kas = dns_db.ns:new{}
   local now = self:time()

   self:d('send_delayed_multicast_queries', #ql)
   -- note: we _shouldn't_ have duplicate queries, and even if
   -- we do, it doesn't really _matter_.. 
   function maybe_insert_kas(rr)
      -- if too much time has expired, don't bother
      if rr.valid_kas and rr.valid_kas < now
      then
         self:d('valid_kas < now, skipped')
         return
      end
      -- if it's already in, don't bother
      if kas:find_rr(rr)
      then
         self:d('already in kas')
         return
      end
      self:d('new kas', rr)
      kas:insert_rr(rr)
   end
   for i, e in ipairs(ql)
   do
      local q = e.query 
      qd:insert(q)
      self:iterate_matching_query(true, q, kas, maybe_insert_kas)
      self:iterate_matching_query(false, q, kas, maybe_insert_kas)
      if e.rep
      then
         self:query(q, e.rep)
      end
   end
   self:send_multicast_query(qd, kas, nil)
end

function mdns_if:send_delayed_multicast_replies(q)
   if #q == 0 then return end
   self:d('send_delayed_multicast_replies', #q)

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
   self:d('send_delayed_multicast', #p)
   local q, r = mst.array_filter2(p, is_query)
   self:send_delayed_multicast_queries(q)
   self:send_delayed_multicast_replies(r)
end

function mdns_if:handle_multicast_probe(msg)
   self:d('got probe')

   for i, rr in ipairs(msg.ns)
   do
      self:probed_rr(rr)
   end
end

function mdns_if:probed_rr(rr)
   -- get rid of old probes if any
   self:prune_probes()

   local now = self:time()
   rr = self.probe:insert_rr(rr)
   self:update_sl_if_changed(self.probe_sl, rr, now)

   self:queue_check_propagate_rr(rr)
end

function mdns_if:prune_probes()
   local now = self:time()
   local invalid_before = now - KEEP_PROBES_FOR

   self.probe_sl:iterate_while(function (rr)
                                  if rr.next > invalid_before
                                  then
                                     return
                                  end
                                  self.probe:remove_rr(rr)
                                  self.probe_sl:remove(rr)
                                  self:queue_check_propagate_rr(rr)
                                  return true
                               end)
end

function mdns_if:queue_check_propagate_rr(rr)
   self.parent:queue_check_propagate_if_rr(self.ifname, rr)
end

function mdns_if:msg_if_all_answers_known_and_unique(msg)
   for i, q in ipairs(msg.qd)
   do
      local found = false
      self:iterate_matching_query(true, q, msg.an,
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
   self:d('update_rr_ttl', o, ttl)
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
   o.valid = o.time + ttl
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

      self:a(rr.ttl, 'no ttl for cache rr')

      local q = q_for_rr(rr)

      self:iterate_matching_query(true, q, nil,
                                function (rr2)
                                   if rr2:equals(rr)
                                   then
                                      found = true
                                      local ttl = self:get_own_rr_current_ttl(rr2)
                                      if ttl > (rr.ttl * 2)
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

      self.parent:iterate_ifs_matching_q(true, q,
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
      if rr.ttl < IGNORE_TTL_BELOW then return end
      o = nsc:insert_rr(rr) 
      self:d('[cache] added RR', o)
   else
      -- reset active query counter
      o.queries = nil
   end

   -- update ttl fields of the received (and stored/updated) rr
   self:update_rr_ttl(o, rr.ttl, FIELD_RECEIVED)
   
   -- remove/insert it from cached skiplist
   self:update_next_cached(o)

   -- propagate the information (in some form) onwards
   self:queue_check_propagate_rr(o)
end

function mdns_if:update_sl_if_changed(sl, o, v)
   local was = o.next
   if was == v
   then
      return
   end
   sl:remove_if_present(o)
   o.next = v
   if v
   then
      -- this isn't valid in many cases; for example, if we remove
      -- wait_until, it may be that existing valid may be similar, but
      -- already in past => we replace past with past. so can't assert
      -- on this.
      --local now = self:time()
      --self:a(v >= now, 'trying to schedule to past', was, v, now, o)
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
   self:update_sl_if_changed(self.cache_sl, o, v)
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
      self:d('scheduling query', q)
      -- schedule a query for the rr
      self:query(q)
   end
end

function mdns_if:update_next_own(o)
   local v1 = o.wait_until
   local v2 = o.valid
   if v1 and (not v2 or v1 < v2)
   then
      self:update_sl_if_changed(self.own_sl, o, v1)
   else
      self:update_sl_if_changed(self.own_sl, o, v2)
   end
end

function mdns_if:expire_cache_rr(rr)
   self:update_rr_ttl(rr, 0)
   self:update_next_cached(rr)
end

function mdns_if:expire_cache_old_same_name_rtype(rr, invalid_since)
   self.cache:iterate_rrs_for_ll_safe(rr.name,
                                      function (rr2)
                                         if rr2.rtype == rr.rtype 
                                            and rr2.rclass == rr.rclass
                                            and rr2[FIELD_RECEIVED] <= invalid_since
                                         then
                                            self:expire_cache_rr(rr2)
                                         end
                                      end)
end


function mdns_if:upsert_cache_rrs(rrlist)
   if not rrlist or not #rrlist then return end
   local ns = self.own
   local nsc = self.cache
   local now = self:time()
   local invalid_since = now - 1
   for i, rr in ipairs(rrlist)
   do
      if rr.cache_flush
      then
         self:expire_cache_old_same_name_rtype(rr, invalid_since)
      end
      if rr.ttl < IGNORE_TTL_BELOW and not nsc:find_rr(rr) and not ns:find_rr(rr)
      then
         -- skip
      else
         self:upsert_cache_rr(rr)
      end
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
   if not l then return end

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
      elseif rr.ttl and rr.ttl < IGNORE_TTL_BELOW
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
      o.is_own = true

      -- clear out the membership information (could have been in cache)
      self.cache_sl:clear_object_fields(o)

      if o.cache_flush
      then
         self:set_state(o, STATE_P1)
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
      else
         o.ttl = nil
         o.valid = nil
      end

      -- remove/insert it from own skiplist
      self:update_next_own(o)

      if rr.ttl
      then
         self:a(o.valid, 'valid not set for own w/ ttl')
         self:a(o.next, 'next not set for own w/ ttl')
      else
         self:a(not o.valid, 'valid set for own rr w/o ttl')
         -- next may be set, if we're just probing on the interface
         -- (for example)
      end
   end
end


function mdns_if:insert_own_rr(rr)
   self:insert_own_rrset{rr}
end

function mdns_if:set_state(rr, st)
   local w = STATE_DELAYS[st]
   self:d('setting state', rr, st)
   rr.state = st
   if w
   then
      local now = self:time()
      self:a(type(now) == 'number', 'wierd time', now)
      local wu = now + mst.randint(w[1], w[2]) / 1000.0
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
      -- callback is responsible for setting next state
      cb(self, rr)
   else
      -- if no callback, all we do is just set next state, if any
      self:set_next_state(rr)
   end
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
   if self.dirty_nsec
   then
      return 0
   end

   local best, bestsrc
   function maybe(t, src, o)
      if not t then return end
      if not best or t < best
      then
         best = t
         bestsrc = {src, o}
      end
   end
   self:d('looking for next_time', self.cache_sl, self.own_sl, #self.pending)
   -- cache entries' expiration
   local o = self.cache_sl:get_first()
   if o
   then
      maybe(o.next, 'cache', o)
   end
   local o = self.own_sl:get_first()
   if o
   then
      maybe(o.next, 'own', o)
   end
   local q = self.pending
   for e, _ in pairs(q)
   do
      local b = self:schedule_for_e_in_q(e, q)
      maybe(b, 'multicast', e)
   end
   if not self.parent.disable_discovery
   then
      maybe(self.md:next_time(), 'discovery', self.md)
   end
   if best
   then
      self:d('next_time', best, bestsrc)
   end
   return best
end

function mdns_if:gather_in_states(states, lastfield, maxdelay)

   -- first off, check if we succeeded too recently, that means
   -- that this call is spurious
   local now = self:time()
   local last = self[lastfield]
   if last == now
   then
      return 
   end

   local r 
   local ns = self.own
   local waitmore 
   ns:foreach(function (rr)
                 if states[rr.state] 
                 then
                    if rr.wait_until
                    then
                       waitmore = rr.wait_until
                    end
                 end
              end)
   if waitmore and (not last or (now-last) < maxdelay)
   then
      -- as one callback is enough to send all (and update the states
      -- accordingly at that point), we don't schedule new one
      self:d('skipping - waiting for more at', waitmore)
      return 
   end
   ns:foreach(function (rr)
                 if states[rr.state] 
                 then
                    r = r or {}
                    table.insert(r, rr)
                 end
              end)
   if r
   then
      -- as the next-state logic should ensure that if the 
      -- earlier probe/announce causes callback, the rest of probe/callbacks
      -- _also_ change state, there should be never two
      -- concrete multicast-producing calls of same type, at same time.
      -- so make sure it never happens here.
      self:a(not self[lastfield] or self[lastfield] < now, 
             'logic flaw - cannot be spamming multicast')
      self[lastfield] = now
   end
   return r
end

function mdns_if:send_announces()
   -- try to send _all_ eligible announcements at once.  e.g. entries
   -- that are in one of the send-announce states (a1, a2), and their
   -- wait_until is not set, for that interface (or
   -- SEND_ANNOUNCES_EVERY is exceeded)
   local an = self:gather_in_states(announce_states, 
                                    'last_sent_announce', SEND_ANNOUNCES_EVERY)
   if not an then return end
   local now = self:time()
   for i, rr in ipairs(an)
   do
      self:set_next_state(rr)
      rr[FIELD_SENT_MCAST] = now
   end
   -- not unicast, not legacy, force sending (no last sent checks)
   an = self:copy_rrs_with_updated_ttl(an, false, false, true)
   local h = mdns_const.DEFAULT_RESPONSE_HEADER
   local s = dns_codec.dns_message:encode{an=an, h=h}
   local dst = mdns_const.MULTICAST_ADDRESS_IPV6 .. '%' .. self.ifname
   self:d(now, 'sending announce(s)', #an)
   -- XXX ( handle fragmentation )
   self:sendto(s, dst, mdns_const.PORT)
end

function mdns_if:send_probes()
   -- try to send _all_ eligible probes at once.  e.g. entries that
   -- are in one of the send-probe states (a1, a2), and their
   -- wait_until is not set, for that interface (or SEND_PROBES_EVERY
   -- is exceeded)

   local ons = self:gather_in_states(probe_states, 
                                     'last_sent_probe', SEND_PROBES_EVERY)
   if not ons then return end
   local qd = {}
   local tns = dns_db.ns:new{}
   for i, rr in ipairs(ons)
   do
      local found = false
      tns:iterate_rrs_for_ll(rr.name, function () found=true end)
      -- sending query for something that is about to expire doesn't make
      -- sense
      if not found and self:get_own_rr_current_ttl(rr) > 0
      then
         table.insert(qd, q_for_rr(rr, {qtype=dns_const.TYPE_ANY,
                                        qu=true}))
         tns:insert_rr(rr)
      end
      self:set_next_state(rr)
   end
   -- XXX ( handle fragmentation )
   self:d('sending probes', #qd, #ons)
   if #qd == 0
   then
      return
   end
   -- copy the objects s.t. we DON'T update sent timestamps etc
   -- (as these are not considered authoritative), but we DO update ttls
   -- not unicast, not legacy, force sending (no last sent checks)
   ttl_ons = self:copy_rrs_with_updated_ttl(ons, true, true)
   mst.a(#qd <= #ttl_ons, 'somehow eliminated too many prospective answers?', qd, ons)
   self:send_multicast_query(qd, nil, ttl_ons)
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
              
              is_own=true,
      }
      nsec = ns:insert_rr(nsec)
      self:d('[own] added NSEC RR', nsec)
   else
      nsec.rdata_nsec.bits = bits
      -- XXX - should we proactively send updated nsec record if bits
      -- have changed?
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
   local msg, err = dns_codec.dns_message:decode(data)

   -- if message is garbage, we just ignore
   if not msg
   then
      self:d('ignoring garbage - decode error', err)
      return
   end

   -- clear up the dirty nsec entries, if any, that are around
   -- as result of 'other' processing
   self:refresh_dirty_nsecs()

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

function mdns_if:propagate_o_l(o, l)
   -- project: update the 'own' s.t. for anything matching 'o', it
   -- roughly matches 'l' => update own state accordingly.
   

   -- O(n log n)
   local rdata2own = {}
   local ol = self.own:find_rr_list(o)
   for i, rr in ipairs(ol or {})
   do
      rdata2own[dns_db.rr.get_rdata(rr)] = rr
   end

   -- O(n log n)
   local rdata2l = {}
   for i, rr in ipairs(l or {})
   do
      rdata2l[dns_db.rr.get_rdata(rr)] = rr
   end
   
   -- (?) - hopefully efficient
   self:insert_own_rrset(l)

   -- O(n log n-ish)
   for k, rr in pairs(rdata2own)
   do
      local rr2 = rdata2l[k]
      if not rr2
      then
         -- this should be destroyed
         self:start_expire_own_rr(rr)
      end
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
         return q_for_rr(rr, {qtype=dns_const.TYPE_ANY})
      end
   end
   self:d('no queries matching', rr)
end

function mdns_if:start_expire_own_rr(rr)
   self:d('start_expire_own_rr', rr)

   -- nop if already being expired
   if rr.ttl == 0
   then
      return
   end

   -- start ttl=0 process for the rr, and process it on next event
   self:update_rr_ttl(rr, 0)
   
   -- remove/insert it from own skiplist
   self:update_next_own(rr)
end

