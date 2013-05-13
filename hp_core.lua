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
-- Last modified: Mon May 13 17:03:51 2013 mstenber
-- Edit time:     227 min
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

require 'dns_tree'

module(..., package.seeall)

MDNS_TIMEOUT=0.5

DOMAIN='home'

RESULT_FORWARD_EXT='forward_ext' -- forward to the real external resolver
RESULT_FORWARD_INT='forward_int' -- forward using in-home topology
RESULT_FORWARD_MDNS='forward_mdns' -- forward via mDNS

RESULT_NXDOMAIN='nxdomain'

hybrid_proxy = mst.create_class{class='hybrid_proxy',
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
   return n
end

function create_default_nxdomain_node_callback(o)
   local n = dns_tree.create_node_callback(o)
   function n:get_default(req)
      return RESULT_NXDOMAIN
   end
   return n
end


function hybrid_proxy:get_local_ifname_for_prefix(prefix)
   local got
   self:iterate_ap(function (o)
                      if o.prefix == prefix
                      then
                         got = o.ifname
                      end
                   end)
   return got
end

function hybrid_proxy:recreate_tree()
   self.db = dns_db.ns:new{}
   local root = dns_tree.node:new{label=''}
   self.root = root

   -- [4] what we haven't explicitly chosen to take care of (=<domain>
   -- and <domain>'s usable prefixes for reverse) will be
   -- forwarded
   function root:get_default(req)
      return RESULT_FORWARD_EXT
   end
   local rid = self.rid
   local domain_ll = dns_db.name2ll(self.domain)
   local domain = root:find_or_create_subtree(domain_ll,
                                              -- end node
                                              create_default_nxdomain_node_callback,
                                              -- intermediate node
                                              create_default_forward_ext_node_callback)

   local router = domain:add_child(dns_tree.create_node_callback{label=rid})

   -- Populate the reverse zone with appropriate nxdomain-generating
   -- entries as well
   
   self:iterate_usable_prefixes(function (s)
                                   local ll = prefix_to_ll(s)
                                   local o = root:find_or_create_subtree(ll,
                                                                         -- [5r] end node
                                                                         create_default_nxdomain_node_callback,
                                                                         -- [4r] intermediate node
                                                                         create_default_forward_ext_node_callback)
                                end)

   local function create_reverse_hierarchy (o)
      local rid = o.rid
      local iid = o.iid
      local ip = o.ip
      local prefix = o.prefix

      local ll = prefix_to_ll(prefix)

      local function create_domain_node (o)
         local n = create_default_nxdomain_node_callback(o)
         local hp = self
         function n:get_default(req)
            -- [2r] local prefix => handle 'specially'
            if rid == hp.rid
            then
               local ifname = hp:get_local_ifname_for_prefix(prefix)
               self:a(ifname, 'no ifname for prefix', prefix)
               return RESULT_FORWARD_MDNS, ifname, n:get_ll()
            else
               -- [3r] remote rid => query it instead
               return RESULT_FORWARD_INT, ip
            end
         end
         return n
      end
      
      local o = root:find_or_create_subtree(ll,
                                            -- [2r/3r] end node
                                            create_domain_node,
                                            
                                            -- [5r] intermediate node
                                            create_default_nxdomain_node_callback)
      
   end
   self:iterate_ap(create_reverse_hierarchy)

   -- Create forward hierarchy
   local function create_forward_hierarchy(o)
      local rid = o.rid
      local iid = o.iid
      local ip = o.ip
      local prefix = o.prefix

      if rid ~= self.rid
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
         else
            -- XXX - think if just having _one_ ip around is a problem or not?
         end
      else
         -- [2] <link>.<router>[.<domain>] for our entries
         local ifname = self:get_local_ifname_for_prefix(prefix)
         self:a(ifname)
         local n = router:get_child(iid)
         if not n
         then
            n = dns_tree.create_node_callback{label=iid}
            local ifname = self:get_local_ifname_for_prefix(prefix)
            self:a(ifname, 'no ifname for prefix', prefix)
            canned = {}
            function n:get_default()
               return RESULT_FORWARD_MDNS, ifname
            end
            function n:get_value()
               -- XXX 
            end
            router:add_child(n)
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
   error("child responsibility - should call f with ap (rid, iid, ip, prefix[, ifname if local])")
end

function hybrid_proxy:iterate_usable_prefixes(f)
   error("child responsibility - should call f with usable prefixes")
end

function hybrid_proxy:forward(server, req)
   local timeout = 1
   local msg, src, tcp = unpack(req)
   return dns_proxy.forward_process_callback(server, msg, src, tcp, timeout)
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
   self:d('rewrite_dns_req_to_mdns_q', dns_req, ll)

   if not dns_req.qd or #dns_req.qd ~= 1
   then
      return nil, 'weird # of questions ' .. mst.repr(dns_req)
   end

   local q = dns_req.qd[1]
   self:a(q.name, 'no name for query', q)
   local n, err = replace_dns_ll_tail_with_another(q.name, ll, mdns_const.LL)
   if not n then return nil, err end

   local nq = mst.table_copy(q)
   nq.name = n
   return nq
end

function hybrid_proxy:rewrite_mdns_rr_to_dns(rr, ll)
   local n, err = replace_dns_ll_tail_with_another(rr.name, mdns_const.LL, ll)
   if not n then return nil, err end
   local nrr = mst.table_copy(rr)
   -- rewrite name
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
   elseif rr.rtype==dns_const.TYPE_PTR
   then
      local n, err = replace_dns_ll_tail_with_another(rr.rdata_ptr, mdns_const.LL, ll)
      if not n then return nil, err end
      nrr.rdata_ptr = n
   end
   return nrr
end

function hybrid_proxy:create_dns_reply(req)
   local an = mst.array:new{}
   local ar = mst.array:new{}
   local reply = {h={id=req.h.id, 
                     rd=req.h.rd,
                     ra=true,
                     qr=true},
                  qd=req.qd, an=an, ar=ar}
   return reply

end

-- Rewrite the mDNS-oriented RR list to a reply message that can be
-- sent to DNS client.
function hybrid_proxy:rewrite_rrs_from_mdns_to_reply_msg(req, mdns_q, 
                                                         mdns_rrs, ll)
   local r = self:create_dns_reply(req)

   function include_rr(rr)
      -- XXX - figure criteria why not to
      return true
   end

   local matched
   
   for i, rr in ipairs(mdns_rrs)
   do
      if include_rr(rr)
      then

         local nrr, err = self:rewrite_mdns_rr_to_dns(rr, ll)
         if not nrr then return nil, 'error rewriting rr ' .. err end
         if mdns_if.match_q_rr(mdns_q, rr)
         then
            r.an:insert(nrr)
            matched = true
         else
            -- anything not directly matching query is clearly additional
            -- record we may want to include just for fun
            r.ar:insert(nrr)
         end
      end
   end
   if not matched
   then
      r.ar = {}
      r.h.rcode = dns_const.RCODE_NAME_ERROR
   end
   return r
end

function hybrid_proxy:mdns_forward(ifname, req, ll)
   local msg, src, tcp = unpack(req)
   -- On high level, this is really simple process. while underneath
   -- it may involve asynchronous stuff (in relation to mdns caching
   -- etc), as we're running within scr coroutine, this can be done
   -- with simple, synchronous-looking logic.
   self:d('mdns_forward', ifname, req, ll)

   -- First off, convert it to MDNS
   local q, err = self:rewrite_dns_req_to_mdns_q(msg, ll)
   if not q
   then
      self:d('rewrite_dns_req_to_mdns_q failed', err)
      local r = self:create_dns_reply(req)
      msg.h.rcode = dns_const.RCODE_FORMAT_ERROR
      return r, src
   end

   local rrs, err = self.mdns_resolve_callback(ifname, q, MDNS_TIMEOUT)

   if rrs and #rrs>0
   then
      local r = self:rewrite_rrs_from_mdns_to_reply_msg(msg, q, rrs, ll)
      return r, src
   end

   return nil, err
end

function hybrid_proxy:match(req)
   local msg, src, tcp = unpack(req)
   if not msg.qd or #msg.qd ~= 1
   then
      return nil, 'no question/too many questions ' .. mst.repr(msg)
   end
   if not self.root
   then
      self:recreate_tree()
      self:a(self.root, 'root not created despite recreate_tree call?')
   end
   local q = msg.qd[1]
   return self.root:match_ll(q.name)
end

function hybrid_proxy:process(msg, src, tcp)
   local req = {msg, src, tcp}
   local r, o, o2 = self:match(req)
   if not r
   then
      return nil, 'match error ' .. mst.repr(o)
   end
   
   -- Next step depends on what we get
   if r == RESULT_FORWARD_INT
   then
      return self:forward(o, req)
   end
   if r == RESULT_FORWARD_EXT
   then
      local server = self.server or '8.8.8.8'
      return self:forward(server, req)
   end
   if r == RESULT_FORWARD_MDNS
   then
      return self:mdns_forward(o, req, o2)
   end
   if r == RESULT_NXDOMAIN
   then
      local r = self:create_dns_reply(msg)
      msg.h.rcode = dns_const.RCODE_NAME_ERROR
      return r, src
   end
   -- _something_ else.. hopefully it's rr's that we need to wrap
   return nil, 'weird result ' .. mst.repr{r, o}
end

