#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_led.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Mar 13 09:38:57 2013 mstenber
-- Last modified: Mon Sep 30 13:33:12 2013 mstenber
-- Edit time:     21 min
--

-- This is used to indicate the pm.lua state to external parties. Two
-- notifications are currently supported:

-- 'pd' indicates there is PD lease received on interfaces

-- 'global' indicates global address has been assigned to an
-- interfaces (ospf-lap)

require 'pm_handler'
require 'mst'

LED_SCRIPT='/usr/share/hnet/led_handler.sh'

module(..., package.seeall)

local _pmh = pm_handler.pm_handler_with_pa
pm_led = _pmh:new_subclass{class='pm_led'}

function pm_led:init()
   _pmh.init(self)
   self.states = {}
   self.enabled = true
end

function pm_led:set_state(ledname, value)
   local old = self.states[ledname]
   if old == value
   then
      return
   end
   self.states[ledname] = value
   self:apply_state(ledname, value)
end

function pm_led:apply_state(ledname, value)
   self:d('applying led state', ledname, value)
   if not self.enabled
   then
      self:d('not enabled, skipping led update')
      return
   end
   local s = 
      string.format('%s %s %s', LED_SCRIPT, ledname, value and '1' or 0)
   self.shell(s)
end

function pm_led:have_pd_prefix_in_skv()
   -- this is a hack; but it can remain a hack too..
   self:d('have_pd_prefix_in_skv')
   -- loop through skv, looking at stuff with prefix
   for k, v in pairs(self._pm.skv:get_combined_state())
   do
      --self:d('key is', k)

      if string.find(k, '^' .. elsa_pa.PD_SKVPREFIX) 
      then 
         self:d('considering', k)
         for i, v in ipairs(v)
         do
            if v.prefix
            then
               self:d('found prefix!', v)
               return true
            end
         end
      end
   end
   return false
end

function pm_led:skv_changed(k, v)
   if string.find(k, '^' .. elsa_pa.PD_SKVPREFIX) 
   then 
      for i, v in ipairs(v)
      do
         if v.prefix
         then
            self:queue()
         end
      end
   end
end

function pm_led:have_global_ipv6()
   for i, v in ipairs(self.usp:get_ipv6())
   do
      -- for the time being, we're happy with ULAs too if they're desired
      -- (XXX - should this be the case?)
      return true
   end
   return false
end

function pm_led:run()
   local found = self:have_pd_prefix_in_skv()
   self:set_state('pd', found)

   local found = self:have_global_ipv6()
   self:set_state('global', found)
end

