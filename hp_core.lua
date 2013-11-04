#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue May  7 11:44:38 2013 mstenber
-- Last modified: Mon Nov  4 13:23:03 2013 mstenber
-- Edit time:     528 min
--

-- This is the 'main module' of hybrid proxy; it leaves some of the
-- details external (such as actual socket API etc), and instead just
-- assumes that it is fed requests (msg, src, tcp) or (msg, nil, tcp)
-- tuples, and then it returns either nil, msg, or (msg, dst)
-- _eventually_.  The 'eventually' part is done via scr coroutines.

-- In general, all requests are responded to according to following
-- logic:

-- [1] own target, non-mdns information => reply immediately

-- this is typically the <router>.<domain> or one of dns-sd browse
-- paths - covered by the local db

-- [2] own target => reply via mdns cache / request

-- destination in one of local prefixes (reverse), or local named
-- zones <link>.<router>.<domain> => ask mdns for equivalent .local

-- [3] known target => forward request

-- one of home assigned prefixes (reverse) or home named zones 

-- [4] not home => forward

-- destination not reverse zone for one of local usable prefixes, and
-- the domain itself is not <domain>

-- [5] default => nxdomain 

-- attempt at using non-existent domain in home zone


-- TODO:

-- Implement reply filtering in more comprehensive fashion s.t. we
-- never, ever return dangling pointers (e.g. PTR => non-existent
-- AAAA).  Can probably reuse mdns_ospf's
-- reduce_ns_to_nondangling_array.

require 'mst'

-- some utility stuff here; should probably refactor to non-mdns
-- module..
require 'mdns_if'

require 'dns_server'
local _dns_server = dns_server.dns_server

module(..., package.seeall)

-- let's consider MDNS spec.
-- first query delay = 20-120ms
-- responder can delay up to 500ms on ethernet
-- processing delay can be <250ms (otherwise probe could be horribly broken
-- => let's guess 1 second and hope it's accurate enough
MDNS_TIMEOUT=1

-- has to be more than MDNS_TIMEOUT; preferably significantly more
FORWARD_TIMEOUT=2

DOMAIN='home'
RIDPREFIX='r-'
IIDPREFIX='i-'

RESULT_FORWARD_EXT='forward_ext' -- forward to the real external resolver
RESULT_FORWARD_INT='forward_int' -- forward using in-home topology
RESULT_FORWARD_MDNS='forward_mdns' -- forward via mDNS

-- mdns depends on POOF to some degree -> it has hour-long TTLs for
-- some entries. We cannot do that, though, and therefore we force TTL
-- to be relatively short no matter what.
DEFAULT_MAXIMUM_TTL=120

-- We enforce this on the results we provide; ttl=0 may cause trouble
-- in various places, and in general it seems like nonsensical
-- answer. Note: This TTL is applied _only_ to DNS responses generated
-- locally. It is NOT applied to forwarded ones (hopefully the other
-- end knows what they're doing). But it IS applied to mdns->dns
-- proxied results.
DEFAULT_MINIMUM_TTL=30

hybrid_proxy = _dns_server:new_subclass{class='hybrid_proxy',
                                        mandatory={'rid', 'domain', 
                                                   'mdns_resolve_callback',
                                        },
                                        events={'rid_changed'},
                                        maximum_ttl=DEFAULT_MAXIMUM_TTL,
                                        minimum_ttl=DEFAULT_MINIMUM_TTL,
                                       }

function hybrid_proxy:init()
   -- superclass init
   _dns_server.init(self)

   -- currently pending list of operations; they're indexed with
   -- mst.repr of {q, is_tcp} and resulting array contains done-flag +
   -- result value (may be nil)
   self.forward_ops = {}
end

function create_default_forward_ext_node_callback(o)
   local n = dns_tree.create_node_callback(o)
   function n:get_default(req)
      return RESULT_FORWARD_EXT
   end
   function n:get_value(req)
      return RESULT_FORWARD_EXT
   end
   mst.d('created default forward node', n)
   return n
end

function create_default_inherit_node_callback(o)
   -- inherit from the parent
   local n = dns_tree.create_node_callback(o)
   function n:get_default(req)
      return n.parent:get_default(req)
   end
   -- inherited default value sounds weird, so we don't do that
   function n:get_value(req)
      return nil
   end
   mst.d('created default inherit node', n)
   return n
end

function hybrid_proxy:get_rid()
   self:a(self.rid, 'no rid?!?')
   return self.rid
end

function hybrid_proxy:set_rid(rid)
   if self.rid == rid
   then
      return
   end
   self.rid = rid
   self.rid_changed()
end

function hybrid_proxy:repr_data()
   return mst.repr{rid=self.rid}
end

function hybrid_proxy:get_local_ifname_for_prefix(prefix)
   local got
   self:a(prefix, 'no prefix provided')
   self:iterate_lap(function (o)
                       if o.prefix == prefix
                       then
                          got = o.ifname
                       end
                    end)
   return got
end

function hybrid_proxy:add_browse(n)
   for i, d in ipairs{dns_const.B_DNS_SD_LL,
                      dns_const.LB_DNS_SD_LL}
   do
      local b_dns_sd_ll = mst.table_copy(d)
      mst.array_extend(b_dns_sd_ll, self.domain_ll)

      local d = {
         name=b_dns_sd_ll,
         rtype=dns_const.TYPE_PTR,
         rclass=dns_const.CLASS_IN,
         rdata_ptr=n:get_ll(),
      }
      self:add_rr(d)
   end
end

function hybrid_proxy:create_local_forward_node(router, o)
   local iid = o.iid
   local liid = self:iid2label(iid)
   local n_ret

   -- [2] <link>.<router>[.<domain>] for our entries
   local ifname = o.ifname
   -- (another option: self:get_local_ifname_for_prefix(prefix))
   self:a(ifname)
   local n = router:get_child(liid)

   if not n then
      -- creating the node
      n = dns_tree.create_node_callback{label=liid}
      function n:get_default()
         local ll = n:get_ll()
         self:a(ll)
         return RESULT_FORWARD_MDNS, {ifname, ll}
      end
      n.value = {}
      function n:get_value()
         return self.value
      end
      router:add_child(n)
      mst.d('defined (own)', n:get_fqdn())

      -- add it to browse domain
      self:add_browse(n)

      -- This function returns the node if it created it
      n_ret = n
   end

   local ip = o.address
   -- For some reasons, address is sometime nil
   if type(ip) ~= "string" then return n_ret end

   -- creating A or AAAA rr for <link>.<router>.<domain>
   local rr = {name={liid, router.label, unpack(dns_db.name2ll(self.domain))}}
   if ipv6s.address_is_ipv4(ip) then
      rr.rtype=dns_const.TYPE_A
      rr.rdata_a=ip
   else
      rr.rtype=dns_const.TYPE_AAAA
      rr.rdata_aaaa=ip
   end
   table.insert(n.value, rr)

   -- We want <router>.<domain> to answer at most one A and one AAAA
   local insert = true
   for i, v in ipairs(router.value)
   do
      if v.rtype == rr.rtype then
         insert = false
         break
      end
   end
   if insert then
      table.insert(router.value, rr)
   end

   return n_ret
end

function hybrid_proxy:create_local_reverse_node(root, router, o)
   -- no prefix -> we can't create reverse hierarchy for this
   local prefix = o.prefix
   if not prefix
   then
      return
   end

   local fcs = root.find_or_create_subtree
   local ll = dns_db.prefix2ll(prefix)
   local iid = o.iid
   local liid = self:iid2label(iid)
   
   local function create_domain_node (o)
      local n = dns_server.create_default_nxdomain_node_callback(o)
      local hp = self
      function n:get_default(req)
         -- [2r] local prefix => handle 'specially'
         local ifname = hp:get_local_ifname_for_prefix(prefix)
         self:a(ifname, 'no ifname for prefix', prefix)
         local on = router:get_child(liid)
         self:a(on, 'forward hierarchy creation bug?')
         local ll = on:get_ll()
         self:a(ll)
         return RESULT_FORWARD_MDNS, {ifname, ll}
      end
      mst.d(' (actually domain node)')
      return n
   end
   local o = fcs(root, ll,
                 -- [2r/3r] end node
                 create_domain_node,
                 -- [5r] intermediate node
                 dns_server.create_default_nxdomain_node_callback)

   return o
end

function hybrid_proxy:create_remote_zone(root, zone)
   local fcs = root.find_or_create_subtree
   local ip = zone.ip
   --self:a(ip, 'no ip address for the zone', zone)
   self:a(not ip or not string.find(ip, '/'), 'ip should not be prefix', ip)
   self:a(zone.name, 'no name for zone?!?', zone)

   local ll = dns_db.name2ll(zone.name)

   local n = fcs(root, ll,
                 function (o)
                    local n = dns_tree.create_node_callback(o)
                    function n:get_default()
                       if ip
                       then
                          return RESULT_FORWARD_INT, ip
                       end
                       return RESULT_FORWARD_EXT
                    end
                    n.get_value = n.get_default
                    return n
                 end,
                 -- we inherit the default behavior; hopefully
                 -- parent exists or we're sol..  (it should
                 -- though, at least the root node if nothing else)
                 create_default_inherit_node_callback)
   
   if n and zone.browse
   then
      self:add_browse(n)
   end
   return n
end

function hybrid_proxy:recreate_tree()
   local root = _dns_server.recreate_tree(self)
   local fcs = root.find_or_create_subtree
   local myrid = self:get_rid()
   local mylabel = self:rid2label(myrid)

   -- [4] what we haven't explicitly chosen to take care of (=<domain>
   -- and <domain>'s usable prefixes for reverse) will be
   -- forwarded
   function root:get_default(req)
      return RESULT_FORWARD_EXT
   end
   self.domain_ll = dns_db.name2ll(self.domain)
   -- create .local zone too, which always says NXDOMAIN
   local localz = fcs(root, mdns_const.LL,
                      -- end node
                      dns_server.create_default_nxdomain_node_callback,
                      -- intermediate node
                      create_default_forward_ext_node_callback)
   function localz:get_value(req)
      self:d('returning nxdomain [local zone]')
      return dns_server.RESULT_NXDOMAIN
   end

   local domain = fcs(root, self.domain_ll,
                      -- end node
                      dns_server.create_default_nxdomain_node_callback,
                      -- intermediate node
                      create_default_forward_ext_node_callback)

   -- Create <router>.<domain> node
   local router_node = dns_tree.create_node_callback{label=mylabel}
   router_node.value = {}
   function router_node:get_value()
      return self.value
   end
   local router = domain:add_child(router_node)

   -- Create forward hierarchy
   self:iterate_lap(
      function (o)
         self:create_local_forward_node(router, o)
      end)

   -- Create reverse hierarchy
   local function create_reverse_zone(s)
      local ll = dns_db.prefix2ll(s)
      local o = fcs(root, ll,
                    -- [5r] end node
                    dns_server.create_default_nxdomain_node_callback,
                    -- [4r] intermediate node
                    create_default_forward_ext_node_callback)
   end
   
   self:iterate_usable_prefixes(create_reverse_zone)

   self:iterate_lap(function (o)
                       self:create_local_reverse_node(root, router, o)
                    end)

   -- XXX - populate [1]
   -- (what static information _do_ we need?)

   -- Remote zones - forward/reverse, we don't care
   self:iterate_remote_zones(
      function (o)
         self:create_remote_zone(root, o)
      end)
end

function hybrid_proxy:iterate_lap(f)
   -- iid mandatory
   -- ifname, prefix optional (but very nice to have)
   error("child responsibility - should call f with lap (iid[, prefix][, ifname])")
end

function hybrid_proxy:iterate_remote_zones(f)
   -- for remote, all we need is name + ip
   -- optionally, can have 'browse' and 'search' set too
   --error("child responsibility - should call f with {name,ip}")
   
   -- for the time being, this is just nop; therefore, by default, we
   -- have no remote zones..
end

function hybrid_proxy:iterate_usable_prefixes(f)
   -- by default, iterating just through ap's prefixes - bit less
   -- elegant layout (it may ask outside for non-assigned prefixes)
   self:iterate_lap(function (ap)
                       if ap.prefix
                       then
                          f(ap.prefix)
                       end
                    end)
end

local function default_nreq_callback(o)
   return dns_channel.msg:new(o)
end

function hybrid_proxy:forward(req, server, nreq_callback)
   nreq_callback = nreq_callback or default_nreq_callback
   local key = mst.repr{qd=req:get_msg().qd, 
                        tcp=req.tcp, 
                        ip=server}
   local v = self.forward_ops[key]
   local got, err
   if not v
   then
      self:d('no op key', key)
      v = {false}
      self.forward_ops[key] = v
      local timeout = FORWARD_TIMEOUT
      local nreq 
      nreq = nreq_callback{binary=req:get_binary(),
                           ip=server,
                           tcp=req.tcp}
      got, err = nreq:resolve(timeout)
      if got
      then
         v[2] = got:get_binary()
      else
         self:d('request failed for op key', key, err)
      end
      v[1] = true
      self.forward_ops[key] = nil
   else
      self:d('waiting for op key', key)

      -- yield the coroutine; eventually we should be done
      coroutine.yield(function () return v[1] end)
      local got_binary = v[2]
      if got_binary
      then
         got = nreq_callback{binary=got_binary}
         -- change the id
         local msg = got:get_msg()

         -- decode failure; due to transparency, we should just re-do
         -- request and handle the binary payload response only
         if not msg
         then
            self:d('unable to decode message', mst.string_to_hex(got_binary))
            return self:forward(req, server, nreq_callback)
         end
         -- copy the id
         self:a(msg.h.id, 'no id in msg?!?', msg)
         msg.h.id = req:get_msg().h.id
         got.binary = nil
      else
         self:d('request failed for op key', key, v)
      end
   end
   if got
   then
      got.ip=req.ip
      got.port=req.port
      got.tcp=req.tcp
   end
   return got
end

function ll_tail_matches(ll, tail)
   local ofs = #ll - #tail
   if ofs <= 0
   then
      --mst.d('too short', ll, tail)
      return nil
      -- inefficient, skip
      --, 'too short name ' .. mst.repr{ll, tail, tail2, ofs}
   end
   -- figure the domain part
   local ll1 = mst.array_slice(ll, ofs+1)

   -- if they're not equal according to dns_db form, we have problem
   local k = dns_db.ll2key(tail)
   local k1 = dns_db.ll2key(ll1)
   if k ~= k1
   then
      --mst.a(not mst.repr_equal(tail, ll1), 'same?!?')
      --mst.d('key mismatch', ll1, tail, mst.repr(k), mst.repr(k1))
      return nil
      -- very inefficient - do we really want to do this?
      --, 'domain mismatch ' .. mst.repr{dns_req, ll}
   end
   return true, ofs
end


function replace_dns_ll_tail_with_another(ll, tail1, tail2)
   mst.a(ll and tail1 and tail2, 'invalid arguments', ll, tail1, tail2)

   -- special case: if it's one of arpa ones, we return ll as-is
   if ll_tail_matches(ll, dns_const.REVERSE_LL_IPV4) or
      ll_tail_matches(ll, dns_const.REVERSE_LL_IPV6) 
   then
      mst.d('found arpa', ll)
      return ll
   end
   mst.d('no arpa', ll)

   local r, ofs = ll_tail_matches(ll, tail1)
   -- if not valid tail, we have to bail
   if not r
   then
      return nil, ofs
   end
   local n = mst.array_slice(ll, 1, ofs)
   n:extend(tail2)
   return n
end



-- Rewrite the DNS-originated request to a single mDNS
-- question. Underlying assumption is that the DNS-originated request
-- is sane (and we check it), containing only one question. We
-- transform the 'domain' within req (and the q within it) from 'll'
-- to mDNS .local while we are at it.
function hybrid_proxy:rewrite_dns_req_to_mdns_q(dns_req, ll)
   self:a(dns_req and dns_req.get_msg, 'weird dns_req', dns_req)
   local msg = dns_req:get_msg()
   self:d('rewrite_msg_to_mdns_q', msg, ll)
   self:a(msg and ll, 'no msg/ll')

   if not msg.qd or #msg.qd ~= 1
   then
      return nil, 'weird # of questions ' .. mst.repr(msg)
   end

   local q = msg.qd[1]
   self:a(q.name, 'no name for query', q)
   local n, err = replace_dns_ll_tail_with_another(q.name, ll, mdns_const.LL)
   if not n then return nil, err end

   local nq = mst.table_copy(q)
   nq.name = n
   return nq
end

function hybrid_proxy:rewrite_mdns_rr_to_dns(rr, ll)
   -- this should not be necessary; resolve_ifname_q should already
   -- perform copy of the resulting rr's, so we can do what we want
   -- with them here..
   --rrr = mst.table_copy(rr)

   -- there is no cache flush in dns-land
   rr.cache_flush = nil

   -- rewrite name
   local n, err = replace_dns_ll_tail_with_another(rr.name, mdns_const.LL, ll)
   if not n then return nil, err end
   rr.name = n
   
   -- manually rewrite the relevant bits.. sigh SRV, PTR are only
   -- types we really care about; NS shouldn't happen
   if rr.rtype == dns_const.TYPE_SRV
   then
      local srv = mst.table_copy(rr.rdata_srv)
      rr.rdata_srv = srv
      local n, err = replace_dns_ll_tail_with_another(srv.target, mdns_const.LL, ll)
      if not n then return nil, err end
      srv.target = n
      return rr
   end

   if rr.rtype == dns_const.TYPE_PTR
   then
      local n, err = replace_dns_ll_tail_with_another(rr.rdata_ptr, mdns_const.LL, ll)
      if not n then return nil, err end
      rr.rdata_ptr = n
      return rr
   end

   if rr.rtype == dns_const.TYPE_AAAA
   then
      -- check for linklocal - if so, skip this altogether
      if ipv6s.address_is_linklocal(rr.rdata_aaaa)
      then
         return
      end
   end

   -- XXX - what to do with nsec?

   return rr
end

-- Rewrite the mDNS-oriented RR list to a reply message that can be
-- sent to DNS client.
function hybrid_proxy:rewrite_rrs_from_mdns_to_reply_msg(req, mdns_q, 
                                                         mdns_rrs, ll)
   local rm = self:create_dns_reply(req)
   local r = rm:get_msg()
   self:d('rewrite_rrs_from_mdns_to_reply_msg', req, mdns_q, mdns_rrs, ll)

   local matched

   
   for i, rr in ipairs(mdns_rrs)
   do
      local matches_q = mdns_if.match_q_rr(mdns_q, rr)
      self:a(rr.ttl, 'no ttl set in record from mdns?!?', rr)
      local nrr, err = self:rewrite_mdns_rr_to_dns(rr, ll)
      if nrr
      then
         if nrr.ttl < self.minimum_ttl
         then
            nrr.ttl = self.minimum_ttl
         end
         if nrr.ttl > self.maximum_ttl
         then
            nrr.ttl = self.maximum_ttl
         end
         if matches_q
         then
            self:d('adding to an', nrr)
            r.an:insert(nrr)
            matched = true
         else
            -- anything not directly matching query is clearly additional
            -- record we may want to include just for fun
            self:d('adding to ar', nrr)
            r.ar:insert(nrr)
         end
      else
         self:d('invalid rr skipped', rr, ll)
      end
   end
   if not matched
   then
      r.ar = {}
      r.h.rcode = dns_const.RCODE_NXDOMAIN
      self:d('no matches, returning nxdomain')
   end
   return rm
end

function hybrid_proxy:mdns_forward(req, ifname, ll)
   self:d('mdns_forward', ifname, ll)

   -- On high level, this is really simple process. while underneath
   -- it may involve asynchronous stuff (in relation to mdns caching
   -- etc), as we're running within scr coroutine, this can be done
   -- with simple, synchronous-looking logic.

   -- First off, convert it to MDNS
   local q, err = self:rewrite_dns_req_to_mdns_q(req, ll)
   if not q
   then
      self:d('rewrite_dns_req_to_mdns_q failed', err)
      local r = self:create_dns_reply(req,
                                      {h={rcode=dns_const.RCODE_FORMERR}})
      return r
   end

   local rrs, err = self.mdns_resolve_callback(ifname, q, MDNS_TIMEOUT)

   -- if it's non-error, return it, even if result is empty
   if rrs 
   then
      local r = self:rewrite_rrs_from_mdns_to_reply_msg(req, q, rrs, ll)
      return r
   end

   return nil, err
end

function hybrid_proxy:get_server()
   return self.server or dns_const.GOOGLE_IPV4
end

function hybrid_proxy:process_match(req, r, o)
   -- Next step depends on what we get
   if r == RESULT_FORWARD_INT
   then
      if o
      then
         -- server specified
         return self:forward(req, o)
      end
      -- by default, if we don't know about the server, it's NXDOMAIN time!
      -- log it just in case we care
      self:d('unknown internal forward', req)
      r = dns_server.RESULT_NXDOMAIN
   end
   if r == RESULT_FORWARD_EXT
   then
      local server = self:get_server()
      if server
      then
         return self:forward(req, server)
      end
      self:d('unknown external forward', req)
      r = dns_server.RESULT_NXDOMAIN
   end
   if r == RESULT_FORWARD_MDNS
   then
      return self:mdns_forward(req, unpack(o))
   end
   -- if it's list of rrs, overwrite ttls if any
   if type(r) == 'table'
   then
      for i, rr in ipairs(r)
      do
         if not rr.ttl or rr.ttl < self.minimum_ttl
         then
            self:d('setting rr ttl to minimum', rr)
            rr.ttl = self.minimum_ttl
         end
      end
   end
   return _dns_server.process_match(self, req, r, o)
end

function hybrid_proxy:rid2label(rid)
   return RIDPREFIX .. rid
end

function hybrid_proxy:iid2label(iid)
   return IIDPREFIX .. iid
end

