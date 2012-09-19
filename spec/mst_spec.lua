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
-- Last modified: Wed Sep 19 16:53:20 2012 mstenber
-- Edit time:     11 min
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
