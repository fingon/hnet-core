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
-- Last modified: Thu Nov  8 07:55:55 2012 mstenber
-- Edit time:     5 min
--

-- single pm handler prototype

require 'mst'

module(..., package.seeall)

pm_handler = mst.create_class{class='pm_handler', 
                              mandatory={'pm'},
                              events={'changed'}}

function pm_handler:repr_data()
   return '?'
end

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
   self:d('maybe_run')

   if not self:ready()
   then
      self:d(' not ready')
      return
   end
   if not self.queued
   then
      self:d(' not queued')
      return
   end
   self.queued = nil
   self:run()
end

function pm_handler:run()
   -- REALLY implemented by the children
end
