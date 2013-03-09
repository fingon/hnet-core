#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_fakedhcpv6d.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Feb 26 18:35:40 2013 mstenber
-- Last modified: Fri Mar  8 11:22:59 2013 mstenber
-- Edit time:     43 min
--

-- This is minimalist-ish DHCPv6 IA_NA handling daemon (and obviously,
-- stateless queries too).

-- Both are answered based on the state we have gathered via OSPF
-- (from OSPF_LAP, and OSPF-DNS* respectively)

-- There isn't any address pool management as such; instead, we hash
-- the duid, and hope there isn't collisions.. (given 2^64 bits to
-- play with, and 1-2 test clients, that seems like a safe assumption)

-- 'run' handles join/leave to multicast groups 

-- recvmsg callback on the other hand handles actual replies to
-- clients, if they're on interfaces we care about

require 'pm_handler'
require 'mcastjoiner'
require 'dhcpv6_const'
require 'scb'
require 'dnsdb'
require 'dhcpv6codec'
require 'pm_radvd'

module(..., package.seeall)

local _pmh = pm_handler.pm_handler

pm_fakedhcpv6d = _pmh:new_subclass{class='pm_fakedhcpv6d',
                                   port=dhcpv6_const.SERVER_PORT}

function pm_fakedhcpv6d:init()
   -- call superclass init
   _pmh.init(self)

   -- and initialize our listening socket
   self:init_socket()
end

function pm_fakedhcpv6d:uninit()
   self.o:done()
end

function pm_fakedhcpv6d:init_socket()
   local o, err = scb.new_udp_socket{host='*', 
                                     port=self.port,
                                     callback=function (data, src, srcport)
                                        self:recvfrom(data, src, srcport)
                                     end,
                                     v6only=true,
                                    }
   self:a(o, 'unable to initialize socket', err)
   local s = o.s
   self.mcj = mcastjoiner.mcj:new{mcast6=dhcpv6_const.ALL_RELAY_AGENTS_AND_SERVERS_ADDRESS, mcasts=s}
   self.o = o
end

function pm_fakedhcpv6d:ready()
   return self.pm.ospf_lap
end

function pm_fakedhcpv6d:update_master_set()
   local master_if_set = mst.set:new{}
   for i, lap in ipairs(self.pm.ospf_lap)
   do
      if lap.owner and not lap.depracate
      then
         master_if_set:insert(lap.ifname)
      end
   end
   self:d('updating master set', master_if_set)
   self.mcj:set_if_joined_set(master_if_set)
   self.master_if_set = master_if_set
end

function pm_fakedhcpv6d:run()
   self:update_master_set()
end

function pm_fakedhcpv6d:recvfrom(data, src, srcport)
   local l = mst.string_split(src, '%')

   if #l ~= 2
   then
      self:d('weird source address - global?', src)
      return
   end

   if tonumber(srcport) ~= dhcpv6_const.CLIENT_PORT
   then
      self:d('not from client port - ignoring', src, srcport)
      return
   end

   local addr, ifname = unpack(l)
   if not self.master_if_set[ifname]
   then
      self:d('received packet on non-master interface, ignoring it',
             src, srcport)
      return
   end

   local o, err = dhcpv6codec.dhcpv6_message:decode(data)
   if not o
   then
      self:d('decode error', err)
      return
   end

   -- produce reply
   local o2 = {--type
               type=(o.type == dhcpv6_const.MT_SOLICIT 
                     and dhcpv6_const.MT_ADVERTISE -- only to solicits
                     or dhcpv6_const.MT_REPLY -- otherwise
               ),
               -- transaction id
               xid=o.xid,
               -- server id
               [1] = {option=dhcpv6_const.O_SERVERID, 
                      data="0001000118b4e92e4e65b47f205e"},
   }

   local na
   local supports_pclass

   for i, v in ipairs(o)
   do
      if v.option == dhcpv6_const.O_CLIENTID
      then
         -- - copy O_CLIENTID
         table.insert(o2, v)
      end
      if v.option == dhcpv6_const.O_IA_PD
      then
         self:d('IA_PD noticed, ignoring the client', src, srcport)
         return
      end

      if v.option == dhcpv6_const.O_IA_NA
      then
         na = v
      end

      if v.option == dhcpv6_const.O_ORO
      then
         for i, v2 in ipairs(v)
         do
            if v2 == dhcpv6_const.O_PREFIX_CLASS
            then
               supports_pclass = true
            end
         end
      end
   end

   if na
   then
      local v2 = {option=na.option,
                  iaid=na.iaid,
                  t1=na.t1,
                  t2=na.t2}
      -- produce IA_NA with IAADDR's
      table.insert(o2, v2)

      local found

      if supports_pclass
      then

         -- basically, look at whatever we have on the interface; if
         -- it has prefix class, we provide it
         for i, lap in ipairs(self.pm.ospf_lap)
         do
            if lap.ifname == ifname and lap.pclass
            then
               local p = ipv6s.new_prefix_from_ascii(lap.prefix)
               -- take /64 from the prefix
               local b1 = string.sub(p:get_binary(), 1, 8)
               -- take linklocal address part! should be unique ;)
               local b2 = string.sub(ipv6s.address_to_binary_address(addr), 9, 16)
               local b = b1 .. b2
               local a = ipv6s.binary_address_to_address(b)

               local now = self.pm.time()
               local pref = pm_radvd.abs_to_delta(now, lap[elsa_pa.PREFERRED_KEY], na.t1)
               local valid = pm_radvd.abs_to_delta(now, lap[elsa_pa.VALID_KEY], na.t2)
               local v3 = {option=dhcpv6_const.O_IAADDR,
                           preferred=pref,
                           valid=valid,
                           addr=a}
               local pclass = tonumber(lap.pclass)
               table.insert(v3, {option=dhcpv6_const.O_PREFIX_CLASS, value=pclass})
               table.insert(v2, v3)
               found = true
            end
         end
      end

      if not found
      then
         table.insert(v2, {option=dhcpv6_const.O_STATUS_CODE,
                           code=dhcpv6_const.S_NOADDRS_AVAIL,
                           message='No addresses available, sorry'})
      end
   end
   
   -- add DNS parameters if any
   local dns = self.pm.ospf_dns 
   if dns and #dns > 0
   then
      local o3 = {option=dhcpv6_const.O_DNS_RNS}
      mst.array_extend(o3, dns)
      table.insert(o2, o3)
   end
   local search = self.pm.ospf_dns_search
   if search and #search > 0
   then
      local o3 = {option=dhcpv6_const.O_DOMAIN_SEARCH}
      mst.array_extend(o3, mst.array_map(search, dnsdb.name2ll))
      table.insert(o2, o3)
   end
   
   mst.d('sending reply', o2)
   local b = dhcpv6codec.dhcpv6_message:encode(o2)
   self:sendto(b, src, srcport)
end

function pm_fakedhcpv6d:sendto(data, dst, dstport)
   self.o.s:sendto(data, dst, dstport)
end
