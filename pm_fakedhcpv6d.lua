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
-- Last modified: Tue Feb 26 19:30:09 2013 mstenber
-- Edit time:     16 min
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

function pm_fakedhcpv6d:recvmsg(data, src, srcport)

end
