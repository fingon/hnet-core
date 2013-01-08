#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv6s_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct  1 22:04:20 2012 mstenber
-- Last modified: Tue Jan  8 15:13:03 2013 mstenber
-- Edit time:     55 min
--

require 'ipv6s'
require 'busted'
require 'mst'

module("ipv6s_spec", package.seeall)


describe("address_cleanup", function ()
            it("should work",
               function ()
                  local d = {
                     {"dead:0:0:0:0:0:0:1", "dead::1"},
                  }
                  for i, v in ipairs(d)
                  do
                     local src = v[1]
                     local dst = v[2]
                     local got = ipv6s.address_cleanup(src)
                     mst.a(dst == got, 'unexpected', src, dst, got)
                  end
               end)
                            end)

describe("address_to_binary_address/binary_address_to_address", function ()
            it("should be bidirectional",
               function ()
                  local d = {
                     "dead::1",
                     'fe80::d69a:20ff:fefd:7b50',
                  }
                  for i, o in ipairs(d)
                  do
                     local b = ipv6s.address_to_binary_address(o)
                     mst.a(#b == 16, 'invalid encoded length', o, #b)
                     local got = ipv6s.binary_address_to_address(b)
                     mst.a(o == got, 'unexpected', o, got, mst.string_to_hex(b))
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
                     local enc = ipv6s.address_to_binary_address(v)
                     -- no zero pad guarantee if no :: in the string(?)
                     mst.a(#enc <= 16, 'invalid encoded length', v, #enc)
                     local s = ipv6s.binary_address_to_address(enc)
                     assert.are.same(s, v)
                  end
                        end)
                                                                end)

describe("prefix_to_binary_prefix", function ()
            it("works", function ()
                  local d = {
                     {"dead::/8", 1, 0xde, 0xde},
                     {"dead::/16", 2, 0xde, 0xad},
                     {"dead::/32", 4, 0xde, 0},
                     {"dead::/128", 16, 0xde, 0},
                     {"::dead/128", 16, 0, 0xad},
                  }
                  for i, v in ipairs(d)
                  do
                     local px, elen, efirst, elast = unpack(v)
                     local b = ipv6s.prefix_to_binary_prefix(px)
                     mst.a(b, 'no result')
                     mst.a(#b==elen, 'different len than expected', px, #b, elen)

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

                        end)
            it("works2 [full 64 bits of prefix]", function ()
                  local prefix = 'fdb2:2c26:f4e4:dead::/64'
                  local hwaddr = '00:1c:42:a7:f1:d9'
                  local exp = 'fdb2:2c26:f4e4:dead:21c:42ff:fea7:f1d9/64'
                  local got = ipv6s.prefix_hwaddr_to_eui64(prefix, hwaddr)
                  mst.a(got == exp, got, exp)

                                                  end)
                                   end)

local test_strings = {'::/0', '::/1', '::/8',
                      '8000::/1', '8000::/8', 'dead::/16',
                      '1.2.3.0/24',
                      '1.2.3.4/32',

}

local next_tests = {{'::/0', '::/64', '0:0:0:1::/64'},
                    {'10.0.0.0/8', '10.0.0.0/24', '10.0.1.0/24'},
                    {'10.0.0.0/8', '10.255.255.0/24', '10.0.0.0/24'},
                    -- overflow case, should return self?
                    {'8000::/1', '8000::/64', '8000:0:0:1::/64'},
                    {'8000::/1', 'ffff:ffff:ffff:ffff::/64', '8000::/64'},
                    {'8000::/1', '8000::/1', '8000::/1'},
                    {'8000::/1', '8000::/8', '8100::/8'},
}


describe("ipv6_prefix", function ()
            it("can be initialized in various ways", function ()
                  local p1 = ipv6s.ipv6_prefix:new{binary=string.char(0xDE)..string.char(0xAD)}
                  local p2 = ipv6s.ipv6_prefix:new{ascii='dead::/16'}
                  mst.a(p1:get_ascii() == p2:get_ascii())
                  mst.a(p1:get_binary() == p2:get_binary())
                                                     end)

            it("ipv4 works #v4", function ()
                  local p1 = ipv6s.ipv6_prefix:new{ascii='1.2.3.0/24'}
                  local b1 = p1:get_binary()
                  mst.d('got binary', mst.string_to_hex(b1))
                  local p2 = ipv6s.ipv6_prefix:new{binary=b1}
                  local a2 = p2:get_ascii()
                  mst.a(p1:get_ascii() == a2, 'ascii mismatch', a2)

                                 end)
            it("works with test strings #s", function ()
                  for i, v in ipairs(test_strings)
                  do
                     local p = ipv6s.new_prefix_from_ascii(v)
                     local b = p:get_binary()
                     local bl = p:get_binary_bits()
                     mst.a(bl == 0 or #b > 0, 'get_binary dropping data?', v)
                     mst.d('playing with', p, mst.string_to_hex(b), bl)
                     local p2 = ipv6s.new_prefix_from_binary(b, bl)
                     local a2 = p2:get_ascii()
                     mst.a(a2 == v, 'unable to handle', v, a2, p2, #b)
                  end
                                             end)
            it("get-next works too #n", function ()
                  for i, v in ipairs(next_tests)
                  do
                     local uspa, nowa, exp = unpack(v)
                     local usp = ipv6s.new_prefix_from_ascii(uspa)
                     local now = ipv6s.new_prefix_from_ascii(nowa)
                     local np = now:next_from_usp(usp)
                     local got = np:get_ascii()
                     mst.d('running', usp, now)
                     mst.a(got == exp, 'next does not work', np, exp)

                  end

                                        end)
                        end)

describe("prefix_contains", function ()
            it("works", function ()
                  function test_tv(usp, tv)
                     for i, v in ipairs(tv)
                     do
                        local a, exp = unpack(v)
                        local asp = ipv6s.new_prefix_from_ascii(a)
                        local got = usp:contains(asp)
                        mst.a(got == exp, 'not what expected', usp, asp, got, exp)

                     end

                  end
                  
                  local usp = ipv6s.new_prefix_from_ascii('10.0.0.0/8')
                  local tv = {
                     {'11.0.0.0/24', false},
                     {'9.0.0.0/24', false},
                     {'10.0.0.0/24', true},
                     {'10.255.255.255/24', true},
                     {'10.42.42.42/24', true},
                  }
                  test_tv(usp, tv)
                  local usp = ipv6s.new_prefix_from_ascii('10.0.0.0/7')
                  local tv = {
                     {'11.0.0.0/24', true},
                     {'12.0.0.0/24', false},
                     {'9.0.0.0/24', false},
                  }
                  test_tv(usp, tv)
                        end)
                            end)

-- todo

--function prefix_contains(p1, p2)
--function binary_prefix_next_from_usp(up, p)
