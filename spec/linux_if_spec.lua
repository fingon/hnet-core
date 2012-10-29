#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: linux_if_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct 29 16:05:22 2012 mstenber
-- Last modified: Mon Oct 29 16:20:41 2012 mstenber
-- Edit time:     5 min
--

require "busted"
require 'mst'
require 'linux_if'
require 'dshell'

module("linux_if_spec", package.seeall)

hwaddr_array = {
   {'ifconfig lower | grep HWaddr',
    'lower      Link encap:Ethernet  HWaddr 00:1c:42:a7:f1:d9  '},
   {'ifconfig upper | grep HWaddr',
    'lower      Link encap:Ethernet  HWaddr 00:1C:42:A7:F1:D9  '},
}

describe("if_table", function ()
            local ds
            local ift
            before_each(function ()
                        ds = dshell.dshell:new()
                        ift = linux_if.if_table:new{shell=ds:get_shell()}
                        end)
            it("works - hwaddr", function ()
                  ds:set_array(hwaddr_array)
                  -- two different variants - it seems that hwaddress
                  -- on normal Linux ifconfig is lowercase, but upper on
                  -- busybox(?) on OWRT
                  local hw1 = ift:get_if('lower'):get_hwaddr()
                  local hw2 = ift:get_if('upper'):get_hwaddr()
                  mst.a(hw1)
                  mst.a(hw2)
                  ds:check_used()
                                 end)
             end)
