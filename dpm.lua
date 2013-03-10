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
-- Last modified: Sun Mar 10 16:57:16 2013 mstenber
-- Edit time:     7 min
--

-- dummy version of pm_core's pm class

require 'mst'
require 'dshell'

module(..., package.seeall)

dpm = mst.create_class{class='dpm'}

function dpm:init()
   self.nh = self.nh or {}
   self.ds = self.ds or dshell.dshell:new{}
   self.shell = self.shell or self.ds:get_shell()
   self.if_table = linux_if.if_table:new{shell=self.shell} 
   function self.time()
      return self.t
   end
   self.t = 1234
end


function dpm:get_ipv6_usp()
   return self.ipv6_usps or {}
end

function dpm:get_ipv6_lap()
   return self.ipv6_laps or {}
end

function dpm:get_external_if_set()
   return self.external_ifs or {}
end
