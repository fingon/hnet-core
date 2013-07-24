#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: per_ip_server.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May 16 14:06:16 2013 mstenber
-- Last modified: Wed Jul 24 23:12:33 2013 mstenber
-- Edit time:     29 min
--

-- This is a server instance controller, which maintains per-ip
-- instance of a server, and keeps each of those instances completely
-- separate from each other.

-- The reason for this is simple: Given standard POSIX-ish basic API
-- we get from luasocket, we can't determine target address we receive
-- datagrams at, and we cannot ensure our source address matches that
-- when sending reply. So (for example) our DNS traffic looks like
-- bogons.

-- So what we do, is start one dns server per IP address, and deduce
-- the target from that - we can then use simple sendto/receivefrom on
-- those sockets to get correct-looking source addresses.

-- (In a home network, this should not be necessary (hopefully no
-- strict filters), but it might be, if resolver is paranoid - and we
-- don't lose anything by doing this, so we do it.)

require 'mst'

module(..., package.seeall)

per_ip_server = mst.create_class{class='per_ip_server',
                                 mandatory={'create_callback'}}

function per_ip_server:init()
   self.servers = {}
end

function per_ip_server:repr_data()
   return mst.repr{servers=mst.table_count(self.servers)}
end

function per_ip_server:uninit()
   for ip, o in pairs(self.servers)
   do
      o:done()
   end
   self:detach_skv()
end

function per_ip_server:set_ips(l)
   self:d('set_ips', l)

   -- convert to a set
   local s = mst.array_to_table(l)
   local fails
   mst.sync_tables(self.servers, s,
                   -- remove
                   function (k, o)
                      o:done()
                      self.servers[k] = nil
                   end,
                   -- add
                   function (k, o)
                      local s = self.create_callback(k)
                      if s
                      then
                         self.servers[k] = s
                      else
                         fails = fails or 0
                         fails = fails + 1
                      end
                   end
                  )
   if fails
   then
      self:d('failures', fails, 'retrying in a second')
      local t = ssloop.loop():new_timeout_delta(1, function ()
                                                   self:d('retry callback')
                                                   self:set_ips(l)
                                                   end)
      t:start()
   end

end

function per_ip_server:detach_skv()
   if not self.skv
   then
      return
   end
   self.skv:remove_change_observer(self.f, elsa_pa.OSPF_LAP_KEY)
   self.skv = nil
   self.f = nil
end

function per_ip_server:attach_skv(skv, f)
   -- detach if we already were attached
   self:detach_skv()

   -- and attach now
   self.skv = skv
   self.f = function (_, pl)
      -- we can ignore key, we know it pl = list with
      -- relevant bit the 'address' (while it's just one IP in
      -- practise)

      -- convert to normal IP's
      local l = {}
      for i, lap in ipairs(pl)
      do
         local a = lap.address
         if a
         then
            if not f or f(lap)
            then
               -- is this even neccessary? probably, given where we get
               -- these addresses from..
               a = mst.string_split(a, '/')[1]

               table.insert(l, a)
            end
         end
      end
      self:set_ips(l)
   end
   self.skv:add_change_observer(self.f, elsa_pa.OSPF_LAP_KEY)
end
