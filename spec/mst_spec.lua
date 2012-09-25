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
-- Last modified: Tue Sep 25 13:04:34 2012 mstenber
-- Edit time:     17 min
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
                  local s = "foo"
                  local n = 42
                  assert.are.same(repr(t), '{foo=1}')
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
