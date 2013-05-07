#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hybrid_proxy_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue May  7 11:44:38 2013 mstenber
-- Last modified: Tue May  7 16:51:04 2013 mstenber
-- Edit time:     110 min
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

require 'mst'

-- some utility stuff here; should probably refactor to non-mdns
-- module..
require 'mdns_if'

module(..., package.seeall)

DOMAIN='home'

RESULT_FORWARD_EXT='forward_ext' -- forward to the real external resolver
RESULT_FORWARD_INT='forward_int' -- forward using in-home topology
RESULT_FORWARD_MDNS='forward_mdns' -- forward via mDNS

RESULT_NXDOMAIN='nxdomain'

hybrid_proxy = mst.create_class{name='hybrid_proxy',
                                mandatory={'rid', 'domain'}}

function hybrid_proxy:init()
   self:recreate_db()
end

function prefix_to_ll(s)
   local p = ipv6s.new_prefix_from_ascii(s)
   if p:is_ipv4()
   then
      
   else
      
   end

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
   self:iterate_iid_ifname_prefix(function (iid, ifname, prefix2)
                                     if prefix == prefix2
                                     then
                                        got = ifname
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
   local domain_ll = dns_db.name2ll(self.domain)
   local domain = root:find_or_create_subtree(domain_ll,
                                              -- end node
                                              create_default_nxdomain_node_callback,
                                              -- intermediate node
                                              create_default_forward_ext_node_callback)

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

   local function create_reverse_hierarchy (rid, iid, ip, prefix)
      local ll = prefix_to_ll(prefix)

      local function create_domain_node (o)
         local n = create_default_nxdomain_node_callback(o)
         local canned

         -- [2r] local prefix => handle 'specially'
         if rid == self.rid
         then
            local ifname = self:get_local_ifname_for_prefix(prefix)
            self:a(ifname)
            canned = {RESULT_FORWARD_MDNS, ifname}
         else
            -- [3r] remote rid => query it instead
            canned = {RESULT_FORWARD_INT, ip}
         end
         
         self:a(canned, 'unable to generate canned response')

         function n:get_default(req)
            return unpack(canned)
         end

      end
      
      local o = root:find_or_create_subtree(ll,
                                            -- [2r/3r] end node
                                            create_domain_node,
                                            
                                            -- [5r] intermediate node
                                            create_default_nxdomain_node_callback)
      
   end
   self:iterate_rid_iid_ip_prefix(create_reverse_hierarchy)

   -- Create forward hierarchy
   local function create_forward_hierarchy(rid, iid, ip, prefix)
      if rid ~= self.rid
      then
         -- [3] <router>[.<domain>] for non-own entries
         local o = domain:find_or_create_subtree({rid},
                                                 function (o)
                                                    local n = dns_tree.create_node_callback(o)
                                                    function n:get_default()
                                                       return RESULT_FORWARD_INT, ip
                                                    end
                                                    function n:get_value()
                                                       return RESULT_FORWARD_INT, ip
                                                    end
                                                 end)
         -- XXX - think if just having _one_ ip around is a problem or not?
      else
         -- [2] <link>.<router>[.<domain>] for our entries
         local ifname = self:get_local_ifname_for_prefix(prefix)
         self:a(ifname)
         local o = domain:find_or_create_subtree({iid, rid},
                                                 function (o)
                                                    local n = dns_tree.create_node_callback(o)
                                                    function n:get_default()
                                                       return RESULT_FORWARD_INT, ip
                                                    end
                                                    function n:get_value()
                                                       -- XXX 
                                                    end
                                                 end)
      end
   end
   self:iterate_rid_iid_ip_prefix(create_forward_hierarchy)

   -- XXX - populate [1]
   -- (what static information _do_ we need?)

end

function hybrid_proxy:iterate_rid_iid_ip_prefix(f)
   error("child responsibility - should call f with rid, iid, ip, prefix")
end

function hybrid_proxy:iterate_iid_ifname_prefix(f)
   error("child responsibility - should call f with (local) iid, ifname, prefix")
end

function hybrid_proxy:iterate_usable_prefixes(f)
   error("child responsibility - should call f with usable prefixes")
end

function hybrid_proxy:forward(server, req)
   local timeout = 1
   local msg, src, tcp = unpack(req)
   return dns_proxy.forward_process_callback(server, msg, src, tcp, timeout)
end

function hybrid_proxy:mdns_forward(ifname, req)
   return nil, 'mdns forward not implemented yet'
end

function hybrid_proxy:process(msg, src, tcp)
   local req = {msg, src, tcp}
   if not msg.qd or #msg.qd ~= 1
   then
      return nil, 'no question/too many questions ' .. mst.repr(msg)
   end
   local q = msg.qd[1]
   local r, o = self.root:match(q.name)

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
      return self:mdns_forward(o, req)
   end
   if r == RESULT_NXDOMAIN
   then
      return self:reply(
         -- this is a message
         {
            qd=msg.qd,
            h={id=msg.h.id,
               rcode=dns_const.RCODE_NAME_ERROR,
               qr=true},
         }, req)
   end
   -- _something_ else.. hopefully it's rr's that we need to wrap
   return nil, 'weird result ' .. mst.repr{r, o}
end

function hybrid_proxy:reply(msg, req)
   local msgo, src, tcp = unpack(req)
   -- this 'reply' does not really need to send it. instead, return
   -- value of 'process' needs to be formed only
   return msgo, src
end
