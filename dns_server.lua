#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_server.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed May 15 12:29:52 2013 mstenber
-- Last modified: Wed May 15 13:57:23 2013 mstenber
-- Edit time:     21 min
--

-- This is VERY minimalist DNS server. It abstracts away dns_tree
-- which is used for low-level storage of (number of zones) of RRs,
-- and performs lookups there. Anything beyond that is out of scope.

-- This is _relatively_ high performance, as lookups are performed on
-- tree of hashes, so typical time is proportional only to number of
-- labels in label list. 

require 'mst'
require 'dns_tree'

module(..., package.seeall)

dns_server = mst.create_class{class='dns_server'}

RESULT_NXDOMAIN='nxdomain'

function dns_server:recreate_tree()
   local root = dns_tree.node:new{label=''}
   self.root = root
end

function dns_server:match(req)
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
   local r = {self.root:match_ll(q.name)}
   self:d('got', r)
   return unpack(r)
   --return self.root:match_ll(q.name)
end

function dns_server:process_match(req, r, o, o2)
   local msg, src, tcp = unpack(req)
   -- only result code we supply is NXDOMAIN reply; use that if relevant
   if r == RESULT_NXDOMAIN
   then
      local r = self:create_dns_reply(msg, {h={rcode=dns_const.RCODE_NXDOMAIN}})
      return r, src
   end
   -- has to be a list of rr's from our own storage
   -- (if something else, someone must've done handling before us!
   self:a(type(r) == 'table')
   local r = self:create_dns_reply(msg, {an=r})
   return r, src
end

function dns_server:process(msg, src, tcp)
   -- by default, assume it's query
   -- (this may occur when testing locally and it is not an error)
   local opcode = msg.opcode or dns_const.OPCODE_QUERY
   
   if opcode ~= dns_const.OPCODE_QUERY
   then
      local r = self:create_dns_reply(msg, {h={rcode=dns_const.RCODE_NOTIMP}})
      return r, src
   end
   local req = {msg, src, tcp}
   local r, o, o2 = self:match(req)
   self:d('match result', msg, r, o, o2)
   if not r
   then
      return nil, 'match error ' .. mst.repr(o)
   end
   return self:process_match(req, r, o, o2)
end

function dns_server:create_dns_reply(req, o)
   self:a(req, 'req missing')

   o = o or {}
   o.an = o.an or mst.array:new{}
   o.ar = o.ar or mst.array:new{}
   o.h = o.h or {}
   -- these are always true
   o.h.ra = true -- recursion available
   o.h.qr = true -- reply

   -- these are copied from req, if not specified in o
   o.h.id = o.h.id or req.h.id
   o.h.rd = o.h.rd or req.h.rd
   o.qd = o.qd or req.qd

   return o
end

function create_default_nxdomain_node_callback(o)
   local n = dns_tree.create_node_callback(o)
   function n:get_default(req)
      self:d('returning nxdomain')
      return RESULT_NXDOMAIN
   end
   mst.d('created default nxdomain node', n)
   return n
end


function dns_server:add_rr(rr)
   -- intermediate nodes will be nxdomain ones
   local root = self.root
   self:d('add_rr', rr)
   local o = root:find_or_create_subtree(rr.name,
                                         -- end node
                                         dns_tree.create_leaf_node_callback,
                                         -- intermediate nodes
                                         create_default_nxdomain_node_callback)
   
   if not o.value then o.value = {} end
   local l = o.value 
   for i, v in ipairs(l)
   do
      if v:equals(rr)
      then
         self:d('duplicate, skipping')
         return
      end
   end
   local prr = dns_db.rr:new(mst.table_copy(rr))
   table.insert(l, prr)
   return o
end

