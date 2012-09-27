#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_mst.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Sep 19 16:38:56 2012 mstenber
-- Last modified: Thu Sep 27 18:16:23 2012 mstenber
-- Edit time:     56 min
--

require "luacov"
require "busted"
require "mst"

describe("check_parameters", function ()
            it("blows if omitted parameters", function ()
                  assert.error(function ()
                                  mst.check_parameters("test")

                               end)
                                              end)
            it("works without parameters", function ()
                  mst.check_parameters("test", {}, {})
                                           end)
            it("works with provided parameters", function ()
                  mst.check_parameters("test", {foo=1}, {"foo"})
                                           end)
            it("blows if skipped parameters", function ()
                  assert.error(function ()
                  mst.check_parameters("test", {}, {"foo"})
                               end)
                  
                                              end)
                             end)

describe("create_class", function ()
            it("can create class", function ()
                  local c = mst.create_class()
                  local o = c:new()
                                   end)
            it("can create class with args", function ()
                  local c = mst.create_class{mandatory={"foo"}}
                  assert.error(function ()
                                  local o1 = c:new()
                               end)
                  local o2 = c:new{foo=1}
                  assert.are.same(o2.foo, 1)
                  c.init = function (self)
                     self.bar = self.bar
                  end
                  local o3 = c:new{foo=2}
                  assert.are.same(o3.foo, 2)
                  assert.are.same(o3.bar, 2)

                                             end)

            it("can create + connect events #ev",
               function ()
                  local c1 = mst.create_class{events={'foo'}, class='c1'}

                  local c2 = mst.create_class{class='c1'}
                  for i=1,2
                  do
                     local o1 = c1:new()
                     mst.a(o1.foo, 'event creation failed')
                     local o2 = c2:new()
                     local got = {0}
                     o2:connect(o1.foo, 
                                function (v)
                                   mst.a(v == 'bar', v)
                                   got[1] = 1
                                end)
                     o1.foo('bar')
                     mst.a(got[1] ~= 0)
                     -- try different uninit orders
                     if i == 1
                     then
                        mst.enable_assert = false
                        assert.error(function ()
                                        o1:done()
                                     end)
                        mst.enable_assert = true
                     else
                        o2:done()
                        o1:done()
                     end
                  end

               end)
                         end)

describe("table_copy", function ()
            it("copies tables (shallowly)", function ()
                  local t1 = {foo=1}
                  local t2 = mst.table_copy(t1)
                  t1.bar = 2
                  assert(t1.foo == t2.foo)
                  assert(t1.bar ~= t2.bar)
                                            end)
        end)

describe("table_deep_copy", function ()
            it("copies tables (deep)", function ()
                  local t1 = {foo=1}
                  t1['bar'] = t1
                  local t2 = mst.table_deep_copy(t1)
                  assert(t2.bar == t2)
                                            end)
        end)

describe("repr", function()
            it("works", function ()
                  local repr = mst.repr
                  local t = {foo=1}
                  local a = {1, 'foo'}
                  local s = "foo"
                  local n = 42
                  --mst.enable_debug = true
                  assert.are.same(repr(t), '{foo=1}')
                  assert.are.same(repr(a), '{1, "foo"}')
                  assert.are.same(repr(s), '"foo"')
                  assert.are.same(repr(n), '42')
                        end)
                 end)

describe("array_to_table", function ()
            it("works", function ()
                  local a = {1, 2, 3, 'z'}
                  local t = mst.array_to_table(a)
                  assert(t.z)
                                            end)
        end)

describe('strtol', function()
            it("works", function()
                  assert.are.same(mst.strtol('1011'), 1011)
                  assert.are.same(mst.strtol('fff0', 16), 65535-15)
                        end)
                   end)

describe('strtol', function()
            it("works", function()
                  assert.are.same(mst.strtol('1011'), 1011)
                  assert.are.same(mst.strtol('fff0', 16), 65535-15)
                        end)
                   end)

describe('string_split', function()
            it("works", function()
                  local ir = {
                     {"foo:bar", {"foo", "bar"}},
                     {"foo:", {"foo", ""}},
                     {":foo", {"", "foo"}},
                     {"foo:bar:baz", {"foo", "bar", "baz"}},
                     {"foo:bar::baz", {"foo", "bar", "", "baz"}},
                  }
                  for i, v in ipairs(ir)
                  do
                     local input, output = unpack(v)
                     local got = mst.repr(mst.string_split(input, ':'))
                     local expected = mst.repr(output) 
                     assert.are.same(expected, got)
                  end
                     
                        end)
                         end)

describe('ipv6', function()
            it("works", function()
                  --mst.enable_debug = true
                  local a0 = 'dead:beef'
                  local a1 = 'dead:beef::'
                  local a2 = 'dead:beef::1'
                  local a3 = 'dead:beef::cafe:1'
                  local as = {a0, a1, a2, a3}
                  for i, v in ipairs(as)
                  do
                     local enc = mst.ipv6_ascii_to_binary(v)
                     local s = mst.ipv6_binary_to_ascii(enc)
                     assert.are.same(s, v)
                  end
                        end)
                 end)

