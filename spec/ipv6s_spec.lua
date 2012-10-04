#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv6s_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  1 22:04:20 2012 mstenber
-- Last modified: Thu Oct  4 23:31:40 2012 mstenber
-- Edit time:     25 min
--

require 'ipv6s'
require 'busted'
require 'mst'

describe("ascii_cleanup", function ()
            it("should work",
               function ()
                  local d = {
                     {"dead:0:0:0:0:0:0:1", "dead::1"},
                  }
                  for i, v in ipairs(d)
                  do
                     local src = v[1]
                     local dst = v[2]
                     local got = ipv6s.ascii_cleanup(src)
                     mst.a(dst == got, 'unexpected', src, dst, got)
                  end
               end)
                          end)

describe("ascii_to_binary/binary_to_ascii", function ()
            it("should be bidirectional",
               function ()
                  local d = {
                     "dead::1",
                  }
                  for i, o in ipairs(d)
                  do
                     local b = ipv6s.ascii_to_binary(o)
                     local got = ipv6s.binary_to_ascii(b)
                     mst.a(o == got, 'unexpected', o, got)
                  end
               end)
            it("works", function()
                  local a0 = 'dead:beef'
                  local a1 = 'dead:beef::'
                  local a2 = 'dead:beef::1'
                  local a3 = 'dead:beef::cafe:1'
                  local as = {a0, a1, a2, a3}
                  for i, v in ipairs(as)
                  do
                     local enc = ipv6s.ascii_to_binary(v)
                     local s = ipv6s.binary_to_ascii(enc)
                     assert.are.same(s, v)
                  end
                        end)
                                            end)

describe("prefix_to_bin", function ()
            it("works", function ()
                  local d = {
                     {"dead::/8", 1, 0xde, 0xde},
                     {"dead::/16", 2, 0xde, 0xad},
                     {"dead::/32", 4, 0xde, 0},
                     {"dead::/128", 16, 0xde, 0},
                  }
                  for i, v in ipairs(d)
                  do
                     local px, elen, efirst, elast = unpack(v)
                     local b = ipv6s.prefix_to_bin(px)
                     mst.a(b, 'no result')
                     mst.a(#b==elen, px, elen)

                     local gotf = string.byte(string.sub(b, 1, 1))
                     local gotl = string.byte(string.sub(b, #b, #b))
                     
                     mst.a(gotf == efirst, gotf, efirst)
                     mst.a(gotl == elast, gotl, elast)
                  end
                   end)
                          end)

describe("prefix_hwaddr_to_eui64", function ()
            it("works", function ()
                  -- note: /64, but last short's zeros
                  local prefix = 'fdb2:2c26:f4e4::/64'
                  local hwaddr = '00:1c:42:a7:f1:d9'
                  local exp = 'fdb2:2c26:f4e4::21c:42ff:fea7:f1d9/64'
                  local got = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
                  mst.a(got == exp, got, exp)

                  local gprefix = ipv6s.eui64_to_prefix(exp)
                  mst.a(gprefix == prefix, gprefix, prefix)
                  
                        end)
             end)

-- todo

--function prefix_contains(p1, p2)
--function binary_prefix_next_from_usp(up, p)
