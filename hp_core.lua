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
-- Last modified: Thu May 23 19:53:59 2013 mstenber
-- Edit time:     363 min
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
MDNS_TIMEOUT=0.5

DOMAIN='home'

RESULT_FORWARD_EXT='forward_ext' -- forward to the real external resolver
RESULT_FORWARD_INT='forward_int' -- forward using in-home topology
RESULT_FORWARD_MDNS='forward_mdns' -- forward via mDNS

hybrid_proxy = _dns_server:new_subclass{class='hybrid_proxy',
                                        mandatory={'rid', 'domain', 
                                                   'mdns_resolve_callback',
                                        }}

function prefix_to_ll(s)
   -- We do this in inverse order, and then reverse just in the end
   local p = ipv6s.new_prefix_from_ascii(s)
   local b = p:get_binary()
   local bits = p:get_binary_bits()
   local a

   if p:is_ipv4()
   then
      -- IPv4 is of format
      -- <reverse-ip>.in-addr.arpa
      a = mst.array:new{'arpa', 'in-addr'}
      for i=13,bits/8
      do
         a:insert(tostring(string.byte(string.sub(b, i, i))))
      end
   else
      -- IPv6 is of format
      -- <reverse-ip6-addr-per-hex-octet>.ip6.arpa
      a = mst.array:new{'arpa', 'ip6'}
      -- just whole bytes?
      for i=1,bits/8
      do
         local v = string.byte(string.sub(b, i, i))
         a:insert(string.format('%x', v / 16))
         a:insert(string.format('%x', v % 16))
      end
   end
   a:reverse()
   return a
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

function hybrid_proxy:get_rid()
   self:a(self.rid, 'no rid?!?')
   return self.rid
end

function hybrid_proxy:repr_data()
   return mst.repr{rid=self.rid}
end

function hybrid_proxy:get_local_ifname_for_prefix(prefix)
   local got
   self:a(prefix, 'no prefix provided')
   self:iterate_ap(function (o)
                      if o.prefix == prefix
                      then
                         got = o.ifname
                      end
                   end)
   return got
end

function hybrid_proxy:recreate_tree()
   local root = _dns_server.recreate_tree(self)
   local fcs = root.find_or_create_subtree
   local myrid = self:get_rid()

   self:iterate_ap(function (o)
                      self:a(o.rid, 'rid missing', o)
                      self:a(o.iid, 'iid missing', o)
                      if o.rid == myrid
                      then
                         -- ip not used
                         -- ifname, prefix optional
                      else
                         self:a(o.ip, 'remote ip missing', o)
                      end
                   end)

   -- [4] what we haven't explicitly chosen to take care of (=<domain>
   -- and <domain>'s usable prefixes for reverse) will be
   -- forwarded
   function root:get_default(req)
      return RESULT_FORWARD_EXT
   end
   local domain_ll = dns_db.name2ll(self.domain)
   local domain = fcs(root, domain_ll,
                      -- end node
                      dns_server.create_default_nxdomain_node_callback,
                      -- intermediate node
                      create_default_forward_ext_node_callback)

   local router = domain:add_child(dns_tree.create_node_callback{label=myrid})

   -- Populate the reverse zone with appropriate nxdomain-generating
   -- entries as well

   local function create_reverse_zone(s)
      local ll = prefix_to_ll(s)
      local o = fcs(root, ll,
                    -- [5r] end node
                    dns_server.create_default_nxdomain_node_callback,
                    -- [4r] intermediate node
                    create_default_forward_ext_node_callback)
   end
   
   self:iterate_usable_prefixes(create_reverse_zone)

   local function create_reverse_hierarchy (o)
      -- no prefix -> we can't create reverse hierarchy for this
      local prefix = o.prefix
      if not prefix
      then
         return
      end

      local ll = prefix_to_ll(prefix)
      local rid = o.rid
      local iid = o.iid
      local ip = o.ip

      local function create_domain_node (o)
         local n = dns_server.create_default_nxdomain_node_callback(o)
         local hp = self
         function n:get_default(req)
            -- [2r] local prefix => handle 'specially'
            if rid == myrid
            then
               local ifname = hp:get_local_ifname_for_prefix(prefix)
               self:a(ifname, 'no ifname for prefix', prefix)
               local ll = n:get_ll()
               self:a(ll)
               return RESULT_FORWARD_MDNS, {ifname, ll}
            else
               -- [3r] remote rid => query it instead
               return RESULT_FORWARD_INT, ip
            end
         end
         mst.d(' (actually domain node)')
         return n
      end
      
      local o = fcs(root, ll,
                    -- [2r/3r] end node
                    create_domain_node,
                    -- [5r] intermediate node
                    dns_server.create_default_nxdomain_node_callback)
      
   end
   self:iterate_ap(create_reverse_hierarchy)

   local b_dns_sd_ll = mst.table_copy(dns_const.B_DNS_SD_LL)
   mst.array_extend(b_dns_sd_ll, domain_ll)

   -- Create forward hierarchy
   local function create_forward_hierarchy(o)
      local rid = o.rid
      local iid = o.iid
      local ip = o.ip

      local ap_ll = {iid, rid}
      mst.array_extend(ap_ll, domain_ll)

      -- add it to browse domain
      local d = {
         name=b_dns_sd_ll,
         rtype=dns_const.TYPE_PTR,
         rclass=dns_const.CLASS_IN,
         rdata_ptr=ap_ll
      }
      self:add_rr(d)

      if rid ~= myrid
      then
         -- [3] <router>[.<domain>] for non-own entries
         local n = domain:get_child(rid)
         if not n
         then
            n = dns_tree.create_node_callback{label=rid}
            function n:get_default()
               return RESULT_FORWARD_INT, ip
            end
            function n:get_value()
               return RESULT_FORWARD_INT, ip
            end
            domain:add_child(n)
            mst.d('defined (non-own)', n:get_fqdn())
         else
            -- XXX - think if just having _one_ ip around is a problem or not?
         end
      else
         -- [2] <link>.<router>[.<domain>] for our entries
         local ifname = o.ifname
         -- (another option: self:get_local_ifname_for_prefix(prefix))
         self:a(ifname)
         local n = router:get_child(iid)
         if not n
         then
            n = dns_tree.create_node_callback{label=iid}
            canned = {}
            function n:get_default()
               local ll = n:get_ll()
               self:a(ll)
               return RESULT_FORWARD_MDNS, {ifname, ll}
            end
            function n:get_value()
               -- XXX 
            end
            router:add_child(n)
            mst.d('defined (own)', n:get_fqdn())
         else
            -- XXX do something? 
         end
      end
   end
   self:iterate_ap(create_forward_hierarchy)

   -- XXX - populate [1]
   -- (what static information _do_ we need?)

end

function hybrid_proxy:iterate_ap(f)
   -- for a local, ifname and prefix are optional and ip is not used
   -- for a remote, ip is mandatory; prefix optional
   error("child responsibility - should call f with ap (rid, iid[, ip][, prefix][, ifname if local])")
end

function hybrid_proxy:iterate_usable_prefixes(f)
   -- by default, iterating just through ap's prefixes - bit less
   -- elegant layout (it may ask outside for non-assigned prefixes)
   self:iterate_ap(function (ap)
                      if ap.prefix
                      then
                         f(ap.prefix)
                      end
                   end)
end

function hybrid_proxy:forward(req, server)
   local timeout = 1
   local nreq = dns_channel.msg:new{binary=req:get_binary(),
                                    ip=server,
                                    tcp=req.tcp}
   local got = nreq:resolve(timeout)
   if got
   then
      -- copy some bits so that we forward response to right address
      got.ip = req.ip
      got.port = req.port
      got.tcp = req.tcp
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
   local nrr = mst.table_copy(rr)

   -- there is no cache flush in dns-land
   nrr.cache_flush = nil

   -- rewrite name
   local n, err = replace_dns_ll_tail_with_another(rr.name, mdns_const.LL, ll)
   if not n then return nil, err end
   nrr.name = n
   
   -- manually rewrite the relevant bits.. sigh SRV, PTR are only
   -- types we really care about; NS shouldn't happen
   if rr.rtype == dns_const.TYPE_SRV
   then
      local srv = mst.table_copy(rr.rdata_srv)
      nrr.rdata_srv = srv
      local n, err = replace_dns_ll_tail_with_another(srv.target, mdns_const.LL, ll)
      if not n then return nil, err end
      srv.target = n
      return nrr
   end

   if rr.rtype == dns_const.TYPE_PTR
   then
      local n, err = replace_dns_ll_tail_with_another(rr.rdata_ptr, mdns_const.LL, ll)
      if not n then return nil, err end
      nrr.rdata_ptr = n
      return nrr
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

   return nrr
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
      local nrr, err = self:rewrite_mdns_rr_to_dns(rr, ll)
      if nrr
      then

         if mdns_if.match_q_rr(mdns_q, rr)
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
   end
   return rm
end

function hybrid_proxy:mdns_forward(req, ifname, ll)
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

function hybrid_proxy:process_match(req, r, o)
   -- Next step depends on what we get
   if r == RESULT_FORWARD_INT
   then
      return self:forward(req, o)
   end
   if r == RESULT_FORWARD_EXT
   then
      local server = self.server or dns_const.GOOGLE_IPV4
      return self:forward(req, server)
   end
   if r == RESULT_FORWARD_MDNS
   then
      return self:mdns_forward(req, unpack(o))
   end
   return _dns_server.process_match(self, req, r, o)
end

