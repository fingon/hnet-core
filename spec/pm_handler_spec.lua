#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_handler_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Nov  8 08:25:33 2012 mstenber
-- Last modified: Thu Nov  8 08:32:21 2012 mstenber
-- Edit time:     3 min
--

-- individual handler tests
require 'busted'
require 'dshell'
require 'pm_v6_nh'

module("pm_handler_spec", package.seeall)

describe("pm_v6_nh", function ()
            it("works", function ()
                  local ds = dshell.dshell:new{}
                  local pm = {shell=ds:get_shell()}
                  local o = pm_v6_nh.pm_v6_nh:new{pm=pm}
                  ds:set_array{
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
                                     ]]},                      
                     {'ip -6 route',[[
1.2.3.4 via 2.3.4.5 dev eth0
default via 1.2.3.4 dev eth0
default via 1.2.3.4 dev eth0
                                     ]]},                      
                              }
                  o:tick()
                  o:tick()
                  mst.a(pm.nh:count() == 2, pm.nh)
                  ds:check_used()
                   end)
end)
