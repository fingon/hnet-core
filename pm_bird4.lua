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
-- Last modified: Thu Oct 10 18:10:20 2013 mstenber
-- Edit time:     21 min
--

require 'pm_handler'

module(..., package.seeall)

BIRD4_SCRIPT='/usr/share/hnet/bird4_handler.sh'

local _parent = pm_handler.pm_handler_with_pa

pm_bird4 = _parent:new_subclass{class='pm_bird4'}

function pm_bird4:skv_changed(k, v)
   if k == elsa_pa.OSPF_RID_KEY
   then
      self.rid = v
   end
end

function pm_bird4:stop_bird()
   self.shell(BIRD4_SCRIPT .. ' stop')
   self.bird_rid = nil
end

function pm_bird4:run_start_bird(...)
   local a = mst.array:new{BIRD4_SCRIPT, 'start', ...}
   self.shell(a:join(' '))
end

function pm_bird4:start_bird()
   local rid = self.rid

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
   self:run_start_bird(ips)
   self.bird_rid = rid
end

function pm_bird4:run()
   -- just assume that the bird state sticks, and that it's not
   -- running before we start

   -- need stop if running, and either pid changed,or ipv4 allocations
   -- disappeared
   local lap = self.lap
   local v4 = mst.array_filter(lap, function (lap)
                                  local p = ipv6s.ipv6_prefix:new{ascii=lap.prefix}
                                  return p:is_ipv4() and not lap.depracate
                                    end)
   local rid = self.rid
   self:d('check_bird4', rid, v4:count(), self.bird_rid)


   
   -- first check if we should stop existing one
   if self.bird_rid and v4:count() == 0
   then
      self:stop_bird()
      return 1
   end
   if v4:count()>0 and rid ~= self.bird_rid
   then
      self:start_bird()
      return 1
   end
end

