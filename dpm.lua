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
-- Last modified: Thu Nov  8 09:28:23 2012 mstenber
-- Edit time:     1 min
--

-- dummy version of pm_core's pm class

require 'mst'
require 'dshell'

module(..., package.seeall)

dpm = mst.create_class{class='dpm'}

function dpm:init()
   self.ds = self.ds or dshell.dshell:new{}
   self.shell = self.shell or self.ds:get_shell()
end

function dpm:get_ipv6_usp()
   return self.ipv6_usps or {}
end
