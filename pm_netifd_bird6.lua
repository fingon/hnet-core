#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_bird6.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Oct  9 16:40:25 2013 mstenber
-- Last modified: Thu Oct 10 15:04:32 2013 mstenber
-- Edit time:     10 min
--

-- We assume that we _don't_ really want to run bird6 on every
-- interface any more. Therefore, what we do here, is call a script
-- with the list of the interfaces that are currently _not_ external,
-- but _are_ configured hnet, whenever the list changes.

require 'pm_handler'

module(..., package.seeall)

BIRD6_SCRIPT='/usr/share/hnet/bird6_handler.sh'

local _parent = pm_handler.pm_handler_with_ni

pm_netifd_bird6 = _parent:new_subclass{class='pm_netifd_bird6',
                                       script=BIRD6_SCRIPT}

function pm_netifd_bird6:get_ni_state()
   local devices = mst.set:new()
   self.ni:iterate_interfaces(function (ifo)
                                 local dev = ifo.l3_device or ifo.device
                                 devices:insert(dev)
                              end, false, true)
   local a = devices:keys()
   a:sort()
   return a
end

function pm_netifd_bird6:ni_is_changed()
   local st = self:get_ni_state()
   self:d('run', st)
   if mst.repr_equal(st, self.set_ni_state)
   then
      return
   end
   self.set_ni_state = st
   return true
end

function pm_netifd_bird6:run()
   if not self:ni_is_changed()
   then
      return
   end
   local st = self.set_ni_state
   if st:count() > 0
   then
      self.shell(self.script .. ' start ' .. st:join(' '))
   else
      self.shell(self.script .. ' stop')
   end
end
