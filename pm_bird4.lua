#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_bird4.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 07:15:58 2012 mstenber
-- Last modified: Wed Nov 21 18:36:05 2012 mstenber
-- Edit time:     1 min
--

require 'pm_handler'

module(..., package.seeall)

BIRD4_SCRIPT='/usr/share/hnet/bird4_handler.sh'

pm_bird4 = pm_handler.pm_handler:new_subclass{class='pm_bird4'}

function pm_bird4:run()
   -- just assume that the bird state sticks, and that it's not
   -- running before we start

   -- need stop if running, and either pid changed,or ipv4 allocations
   -- disappeared
   local lap = self.pm.ospf_lap or {}

   local v4 = mst.array_filter(lap, function (lap)
                                  local p = ipv6s.ipv6_prefix:new{ascii=lap.prefix}
                                  return p:is_ipv4() and not lap.depracate
                                    end)
   local rid = self.pm.rid
   self:d('check_bird4', rid, v4:count(), self.bird_rid)


   
   -- first check if we should stop existing one
   if self.bird_rid and (v4:count() == 0 or rid ~= self.bird_rid)
   then
      self.shell(BIRD4_SCRIPT .. ' stop')
      self.bird_rid = nil
      self:changed()
   end
   if v4:count()>0 and rid ~= self.bird_rid
   then
      self:a(rid, 'no rid but wanting to turn on bird, strange')
      -- convert the rid to IPv4
      t = mst.array:new{}
      local v, err = tonumber(rid)
      self:a(v, 'unable to convert rid to number?!?', rid, err)

      for i=1,4
      do
         t:insert(v % 256)
         v = math.floor(v / 256)
      end
      local ips = table.concat(t, '.')

      self.shell(BIRD4_SCRIPT .. ' start ' .. ips)
      self.bird_rid = rid
      self:changed()
   end
end

