#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_handler.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Nov  7 19:33:20 2012 mstenber
-- Last modified: Thu Nov  8 07:35:49 2012 mstenber
-- Edit time:     3 min
--

-- single pm handler prototype

require 'mst'

module(..., package.seeall)

pm_handler = mst.create_class{class='pm_handler', 
                              mandatory={'pm'},
                              events={'changed'}}

function pm_handler:init()
   self.shell = self.pm.shell
end

function pm_handler:queue()
   self.queued = true
end

function pm_handler:ready()
   return true
end

function pm_handler:maybe_run()
   -- if not ready, not going to do a thing
   if not self:ready()
   then
      return
   end
   if self.queued
   then
      self.queued = nil
      self:run()
   end
end

function pm_handler:run()
   -- REALLY implemented by the children
end
