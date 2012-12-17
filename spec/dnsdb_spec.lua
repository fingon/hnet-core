#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnsdb_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 14:37:02 2012 mstenber
-- Last modified: Mon Dec 17 14:44:47 2012 mstenber
-- Edit time:     3 min
--

require "busted"
require "dnsdb"

module("dnsdb_spec", package.seeall)

local fake1 = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'foo', 'bar', ''}
}
local fake2 = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'foo2', 'bar', ''}
}

describe("ns", function ()
            it("works", function ()
                  local ns = dnsdb.ns:new{}
                  mst.a(ns:count() == 0)
                  ns:upsert_rr(fake1)
                  ns:upsert_rr(fake1)
                  mst.a(ns:count() == 1)
                  ns:upsert_rr(fake2)
                  mst.a(ns:count() == 2)
                  local s = {name = fake1.name,
                             rtype = fake1.rtype}
                  local o = ns:find_rr(s)
                  mst.a(o == fake1)
                  ns:remove_rr(fake1)
                  ns:remove_rr(fake2)
                  mst.a(ns:count() == 0)

                   end)
end)
