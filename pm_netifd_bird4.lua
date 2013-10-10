#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_bird4.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Oct 10 13:58:16 2013 mstenber
-- Last modified: Thu Oct 10 18:19:01 2013 mstenber
-- Edit time:     10 min
--

-- as we have strict module = handler mapping, we provide here bird6
-- subclass which just changes the script..

require 'pm_handler'
require 'pm_bird4'
require 'pm_netifd_bird6'

module(..., package.seeall)

local _parent = pm_bird4.pm_bird4
local _bird6 = pm_netifd_bird6.pm_netifd_bird6

pm_netifd_bird4 = _parent:new_subclass{class='pm_netifd_bird4',
                                       sources={
                                          pm_handler.pa_source,
                                          pm_handler.skv_source,
                                          pm_handler.ni_source},
                                       -- no multiple inheritance - 
                                       -- just GRAB the utility methods
                                       ni_is_changed=_bird6.ni_is_changed,
                                       get_ni_state=_bird6.get_ni_state,
                                      }

function pm_netifd_bird4:run_start_bird(...)
   local l = mst.array:new{self, ...}
   l:extend(self.set_ni_state)
   self:d('run_start_bird', l)
   _parent.run_start_bird(unpack(l))
end

function pm_netifd_bird4:run()
   if self:ni_is_changed()
   then
      -- if it already was nil, we don't care, but in general we want
      -- to provoke start's
      self.bird_rid = nil
   end
   return _parent.run(self)
end
