#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dpm.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 09:23:58 2012 mstenber
-- Last modified: Mon Sep 30 15:03:22 2013 mstenber
-- Edit time:     14 min
--

-- dummy version of pm_core's pm class

require 'mst'
require 'dshell'
require 'pm_core'
require 'skv'

local _pm = pm_core.pm

module(..., package.seeall)

dpm = _pm:new_subclass{mandatory={}, class='dpm'}
                      
function dpm:init()
   self.skv = skv.skv:new{port=0, long_lived=true}
   self.ds = self.ds or dshell.dshell:new{}
   self.shell = self.shell or self.ds:get_shell()
   self.t = 1234
   _pm.init(self)
end

function dpm:uninit()
   _pm.uninit(self)
   self.skv:done()
end

function dpm:time()
   return self.t
end
