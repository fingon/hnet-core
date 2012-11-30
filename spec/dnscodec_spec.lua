#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnscodec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 30 12:06:56 2012 mstenber
-- Last modified: Fri Nov 30 12:28:37 2012 mstenber
-- Edit time:     7 min
--

require "busted"
require "dnscodec"

module("dnscodec_spec", package.seeall)

local dns_rr = dnscodec.dns_rr:new{}

local tests = {
   -- minimal
   {dns_rr, {name={}, rtype=1, rdata=''}},
   {dns_rr, {name={'foo', 'bar'}, rtype=2, rclass=3, ttl=4, rdata='baz'}},
}

describe("test dnscodec", function ()
            it("encode + decode =~ same", function ()
                  for i, v in ipairs(tests)
                  do
                     local cl, orig = unpack(v)
                     local b = cl:encode(orig)
                     mst.d('handling', orig)
                     mst.d('encode', mst.string_to_hex(b))
                     local o2, err = cl:decode(b)
                     mst.d('decode', o2, err)
                     mst.a(orig)
                     mst.a(o2, 'decode result empty', err)
                     mst.a(mst.table_contains(o2, orig), "something missing", cl.class, o2, orig)

                  end
                                          end)
end)
