#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv4s_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jun 24 17:57:48 2013 mstenber
-- Last modified: Mon Jun 24 17:58:53 2013 mstenber
-- Edit time:     1 min
--

require 'mst'
require 'ipv4s'
require 'busted'

module("ipv4s_spec", package.seeall)

describe("address_is_loopback", function ()
            it("works", function ()
                  mst.a(ipv4s.address_is_loopback('127.0.0.1'), 'not loopback')
                  mst.a(not ipv4s.address_is_loopback('1.2.3.4'))

                   end)
end)
