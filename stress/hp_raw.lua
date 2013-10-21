#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp_raw.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Oct 16 16:46:45 2013 mstenber
-- Last modified: Mon Oct 21 10:44:58 2013 mstenber
-- Edit time:     112 min
--

-- This is bruteforce-ish code which abuses hybrid proxy.

-- The name of the game is to find out how fast following parts are:

-- DNS forwarding path
-- [1] receive DNS request -> identify forwardable -> forward it
-- [2] receive DNS reply -> forward it back to client

-- MDNS forwarding path 
-- [1] receive DNS request -> identify mdns -> ask mdns
-- [2] mdns done -> forward it back to client

require 'hp_core'
require 'dns_channel'
require 'mst_test'
require 'mst_cliargs'

ptest = mst_test.perf_test:new_subclass{duration=1}

DOMAIN_LL={'foo', 'com'}

-- on top of the fake domain, we'll have 
-- machine + link id + router id labels

RIDPREFIX='r'
IIDPREFIX='i'
MIDPREFIX='m'

function r2l(i)
   return RIDPREFIX .. tostring(i)
end

function i2l(i)
   return IIDPREFIX .. tostring(i)
end

function m2l(i)
   return MIDPREFIX .. tostring(i)
end

-- in parsing order
PREFIXES = {MIDPREFIX, IIDPREFIX, RIDPREFIX}

function ll2mir(ll)
   local result={}
   local state=1
   for _, v in ipairs(ll)
   do
      for i=state,#PREFIXES
      do
         local p = PREFIXES[i]
         local r = mst.string_startswith(v, p)
         --mst.d(' matching', v, p, r)
         if r
         then
            result[p] = r
            state = i+1
            break
         end
      end
   end
   mst.d('ll2mir', ll, result)
   return result[MIDPREFIX], result[IIDPREFIX], result[RIDPREFIX]
end

function mir2ll(m, i, r)
   local data = {[MIDPREFIX]=m, [IIDPREFIX]=i, [RIDPREFIX]=r}
   local l = mst.array:new()
   for i, k in ipairs(PREFIXES)
   do
      local v = data[k]
      if v
      then
         l:insert(k .. tostring(v))
      end
   end
   l:extend(DOMAIN_LL)
   return l
end

function rid_iid_to_pa6(rid, iid)
   -- given numeric rid, iid, return 
   -- IPv6 prefix + addressfor that link
   local p = string.format('dead:%d:%d::/48', rid, iid)
   local a = string.format('dead:%d:%d::1', rid, iid)
   return p, a
end

function rid_iid_to_pa4(rid, iid)
   -- given numeric rid, iid, return 
   -- IPv6 prefix + addressfor that link
   rid = rid + 10 -- start at 10.0.0.0/24
   local p = string.format('%d.%d.%d.0/24', rid, math.floor(iid/256), iid%256)
   local a = string.format('%d.%d.%d.1', rid, math.floor(iid/256), iid%256)
   return p, a
end

function init_hp(nusp, nr, ni, nm)
   mst.a(nusp and nr and ni and nm, 'missing arguments')
   local hp = hp_core.hybrid_proxy:new{rid='0',
                                       domain=DOMAIN_LL,

                                       -- filled in later
                                       mdns_resolve_callback=true,
                                      }

   -- create fake locally assigned prefixes - for both IPv6 and IPv4,
   -- fitting within the first USP prefix
   local lapl = mst.array:new()
   for i=0,ni-1
   do
      local p, a = rid_iid_to_pa6(0, i)
      local iid = tostring(i)
      local ifname = 'eth' .. tostring(i)
      lapl:insert{iid=iid,
                  ip=a,
                  ifname=ifname,
                  prefix=p,
                 }
      local p, a = rid_iid_to_pa4(0, i)
      lapl:insert{iid=iid,
                  ip=a,
                  ifname=ifname,
                  prefix=p,
                 }
   end
   function hp:iterate_lap(f)
      for i, v in ipairs(lapl)
      do
         f(v)
      end
   end
   
   -- create fake usable prefixes
   local uspl = mst.array:new()
   for i=0,nusp-1
   do
      uspl:insert(string.format('dead:%04d::/32', i))
      uspl:insert(string.format('%d.%d.0.0/16',
                                math.floor(i / 256)+10,
                                i % 256))
   end
   function hp:iterate_usable_prefixes(f)
      for i, v in ipairs(uspl)
      do
         f(v)
      end
   end

   -- create fake assign data for remote routers (nr)
   local rzl = mst.array:new()
   for i=1,nr-1
   do
      for j=0,ni-1
      do
         -- forward zone (IPv6 server address)
         local p, a = rid_iid_to_pa6(i, j)
         rzl:insert{
            name=mir2ll(nil, j, i), ip=a,
                   }

         -- reverse zone (IPv6)
         rzl:insert{
            name=dns_db.prefix2ll(p), ip=a
                   }
         -- reverse zone (IPv4)
         local p, a = rid_iid_to_pa4(i, j)
         rzl:insert{
            name=dns_db.prefix2ll(p), ip=a
                   }
      end
   end
   function hp:iterate_remote_zones(f)
      for i, v in ipairs(rzl)
      do
         f(v)
      end
   end
   function hp.mdns_resolve_callback(ifname, q, timeout)
      mst.d('mdns_resolve_callback', ifname, q, timeout)
      -- pretend these are cached replies
      local qname = q.name
      local m, i, r = ll2mir(qname)
      m = tonumber(m)
      r = tonumber(r)
      if qname[#qname] == 'arpa'
      then
         local p, a = rid_iid_to_pa6(0, 0)
         return {name=qname, 
                 rtype=dns_const.TYPE_AAAA, 
                 rdata_aaaa=a, 
                 rclass=dns_const.CLASS_IN,
                 ttl=123,
                 source='r-mdns',
                }
      elseif m >= 0 and m < nm and r == 0
      then
         i = tonumber(i)
         local p, a = rid_iid_to_pa6(0, i)
         return {name=qname, 
                 rtype=dns_const.TYPE_AAAA, 
                 rdata_aaaa=a, 
                 rclass=dns_const.CLASS_IN,
                 ttl=123,
                 source='mdns',
                }
      end

      -- pretend anything else timeouts
      mst.d('timing out', q)
      --scr.sleep(timeout)
      -- if we were really long-lived test in any case, but we aren't
   end
   function hp:forward(req, server)
      local reply

      -- do this to make sure we have struct -> binary conversion step here
      local b = req:get_binary()
      req.msg = nil

      -- and binary -> struct conversion (to represent handling of the reply)
      local q = req:get_msg()
      mst_test.assert_repr_equal(#(q.qd), 1)
      local qname = q.qd[1].name
      if qname[#qname] == 'arpa'
      then
         local p, a = rid_iid_to_pa6(0, 0)
         reply = {an={{name=qname, 
                       rtype=dns_const.TYPE_AAAA, 
                       rdata_aaaa=a, 
                       rclass=dns_const.CLASS_IN,
                       ttl=123,
                       source='r-forward',
                      }
                     },
                  h={
                     id=q.h.id,
                  }
         }
      else
         local m, i, r = ll2mir(qname)
         m = tonumber(m)
         i = tonumber(i)
         r = tonumber(r)
         self:d('got', m, i, r)
         self:a(r > 0)
         if i >= 0 and i < ni
         then
            if r >= 1 and r < nr
            then
               if m >= 0 and m < nm
               then
                  local p, a = rid_iid_to_pa6(r, i)
                  reply = {an={{name=qname, 
                                rtype=dns_const.TYPE_AAAA, 
                                rdata_aaaa=a, 
                                rclass=dns_const.CLASS_IN,
                                ttl=123,
                                source='forward',
                               }
                              },
                           h={
                              id=q.h.id,
                           }
                  }
               end
            end
         end
      end
      if not reply then return end
      local got = dns_channel.msg:new{msg=reply}
      got.ip = req.ip
      got.port = req.port
      got.tcp = req.tcp
      return got
      
   end
   function hp:testq(q)
      local tid = (self.tid or 0) + 1
      self.tid = tid
      local msg = {h={id=tid,
                      opcode=dns_const.OPCODE_QUERY, 
                     },
                   qd={q}}

      local req = dns_channel.msg:new{msg=msg}
      local got = self:process(req)
      self:d('req -> reply', q, got)
      return got
   end
   function hp:testll(name)
      local q = {name=name,
                 qtype=dns_const.TYPE_ANY,
                 qclass=dns_const.CLASS_ANY}
      return self:testq(q)
   end
   function hp:test(m, i, r)
      return self:testll(mir2ll(m, i, r))
   end

   function hp:rid2label(rid)
      return r2l(rid)
   end

   function hp:iid2label(iid)
      return i2l(iid)
   end

   return hp
end

local a = mst_cliargs.parse{
   options={
      {name='debug', flag=true},
      {name='usp',
       convert=tonumber,
       default=2},
      {name='machine',
       convert=tonumber,
       default=5},
      {name='interface',
       convert=tonumber,
       default=4},
      {name='router',
       convert=tonumber,
       default=3},
      {name='testtime',
       convert=tonumber,
       default=1},
   }
                           }

mst.d('got args', a)
hp = init_hp(a.usp, a.router, a.interface, a.machine, a.interface)
hp:test(0, 0, 0)
-- ok, now we can test for real
local ptest = mst_test.perf_test:new_subclass{duration=a.testtime}
if a.debug
then
   ptest.count = 1
end
local mir2ll = ptest:new{cb=function ()
                            mir2ll(0, 0, 0)
                            end, name='mir2ll'}
ptest:new{cb=function ()
             hp:test(0, 0, 0)
end, name='local mdns (fwd)', overhead={mir2ll}}:run()

local a6 = rid_iid_to_pa6(0, 0)
local ll6 = mst.array:new()
ll6:extend{1, 0, 0, 0,
           0, 0, 0, 0}
ll6 = ll6:map(tostring)
ll6:extend(dns_db.prefix2ll(a6))
ptest:new{cb=function ()
             hp:testll(ll6)
end, name='local mdns (reverse)'}:run()


ptest:new{cb=function ()
             hp:test(0, 0, 1)
end, name='remote forward (fwd)', overhead={mir2ll}}:run()

local a6 = rid_iid_to_pa6(1, 0)
local ll6 = mst.array:new()
ll6:extend{1, 0, 0, 0,
           0, 0, 0, 0}
ll6 = ll6:map(tostring)
ll6:extend(dns_db.prefix2ll(a6))
ptest:new{cb=function ()
             hp:testll(ll6)
end, name='remote forward (reverse)'}:run()

ptest:new{cb=function ()
             hp:test(0, 0, a.router)
end, name='nonexistent', overhead={mir2ll}}:run()
