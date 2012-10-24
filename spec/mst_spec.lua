#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_mst.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Wed Sep 19 16:38:56 2012 mstenber
-- Last modified: Wed Oct 17 17:05:01 2012 mstenber
-- Edit time:     95 min
--

require "busted"
require "mst"

module("mst_spec", package.seeall)

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

describe("multimap", function ()  
            it("can be created", function ()
                  local mm = mst.multimap:new()
                  mm:insert('foo', 'bar')
                  assert.are.same(mm:count(), 1)
                                 end)
                     end)

describe("set", function ()
            it("can be created", function ()
                  local s = mst.set:new()
                  mst.a(s)
                  mst.a(s.class == 'set')
                  mst.a(s.is_empty)
                  mst.a(s:is_empty())
                  s:insert('foo')
                  mst.a(s['foo'])
                  mst.a(not s['bar'])
                  s:insert('bar')
                  mst.a(s['bar'])
                  mst.a(not s:is_empty())

                   end)
                end)

describe("array", function ()
            it("can be created", function ()
                  local a = mst.array:new()
                  a:insert(1)
                  a:insert(2)
                  a:insert(3)
                  mst.a(a:count() == 3)
                  mst.a(a:filter(function (x) return x==1 end):count() == 1)
                  -- test that slice works
                  mst.a(mst.repr_equal(a, a:slice()))
                  mst.a(mst.repr_equal(a:slice(2), {2, 3}))
                  mst.a(mst.repr_equal(a:slice(-2), {2, 3}))
                  mst.a(mst.repr_equal(a, a:slice(1, 3)))
                  mst.a(mst.repr_equal(a:slice(1, 2), {1, 2}))
                  mst.a(mst.repr_equal(a:slice(1, 1), {1}))
                  mst.a(mst.repr_equal(a:slice(1, -2), {1, 2}))
                  mst.a(mst.repr_equal(a:slice(1, -3), {1}))
                  a:clear()
                  mst.a(#a == 0)
                   end)
             end)

describe("map", function ()
            it("can be created", function ()
                  local m = mst.map:new()
                  mst.a(m)
                  mst.a(m.class == 'map')
                  mst.a(m.is_empty)
                  mst.a(m:is_empty())
                  m.foo = 'bar'
                  mst.a(not m:is_empty())
                  mst.a(m.foo == 'bar')
                  mst.a(mst.repr_equal(m:keys(), {"foo"}))
                  mst.a(mst.repr_equal(m:values(), {"bar"}))
                  m:clear()
                  mst.a(m:count() == 0)

                                 end)
                end)


describe("bits", function ()
            it("works", function ()
                  local t1 = 1
                  local t2 = 3
                  local t3 = 128
                  local t4 = 127
                  local t5 = 129
                  mst.a(mst.bitv_highest_bit(t1) == 1)
                  mst.a(mst.bitv_highest_bit(t2) == 2)
                  mst.a(mst.bitv_highest_bit(t3) == 8)
                  mst.a(mst.bitv_highest_bit(t4) == 7)
                  mst.a(mst.bitv_highest_bit(t5) == 8)
                  local t6 = mst.bitv_xor_bit(t5, 8)
                  mst.d(t6 == 1)
                  local t7 = mst.bitv_xor_bit(t5, 9)
                  mst.d(t7 == 129+256)
                        end)
end)

describe("execute_to_string", function ()
            it("successful cmd works", function ()
                  local s, err = mst.execute_to_string('ls -1 /')
                  mst.a(s)
                  mst.a(#mst.string_split(s, '\n') > 3)
                                       end)

            -- this one annoyingly enough shows the 'command not
            -- found' even if stderr->stdin redirection is in
            -- place. ugh
            it("erroneous command returns nil", function ()
                  --local s, err = mst.execute_to_string('asfwrherhbdfjv', true)
                  --mst.a(not s)
                  --mst.a(err)
                                                end)
            it("false returns nil", function ()
                  local s, err = mst.execute_to_string('false')
                  mst.a(not s)
                  mst.a(err)
                                    end)
            it("true returns non-nil", function ()
                  local s, err = mst.execute_to_string('true')
                  mst.a(s)
                                       end)
end)

describe("min/max", function ()
            it("min", function ()
                  mst.a(mst.min(1,2,3) == 1)
                  mst.a(mst.min(5,2,3) == 2)
                  mst.a(mst.min(4) == 4)
                  mst.a(mst.min() == nil)
                   end)
            it("max", function ()
                  mst.a(mst.max(1,2,3) == 3)
                  mst.a(mst.max(1,5,3) == 5)
                  mst.a(mst.max(4) == 4)
                  mst.a(mst.max() == nil)
                   end)
end)

describe("cache", function ()
            it("works #cache", function ()
                  local pos_fun = function (k) return k end
                  local neg_fun = function (k) end
                  
                  local c1 = mst.cache:new{get_callback=neg_fun}
                  local t = {0, 0}
                  local c2 = mst.cache:new{time_callback=function ()
                                              return t[1]
                                                         end,
                                           get_callback=function (k)
                                              t[2] = t[2] + 1
                                              return k and true or nil
                                              end}
                  -- test with defaults
                  mst.d('initial')

                  mst.a(c2:get('x') == true)
                  mst.a(c2:get('x') == true)
                  mst.a(t[2] == 1, 'second call should be cached')

                  -- advance time 
                  t[1] = t[1] + c2.default_timeout + 1
                  mst.d('advanced time to', t[1])
                  mst.a(c2:get('x') == true)
                  mst.a(t[2] == 2, 'expired did not clear cache')
                  mst.a(c2:get('x') == true)
                  mst.a(t[2] == 2, 'second call should be cached')

                  -- make sure positive/negative timeouts work if they're different
                  c2.positive_timeout = 8
                  c2.negative_timeout = 5
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 3)
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 3)
                  mst.a(c2:get(true) == true)
                  mst.a(t[2] == 4)
                  mst.a(c2:get(true) == true)
                  mst.a(t[2] == 4)

                  -- advance => negatives should be gone
                  t[1] = t[1] + c2.negative_timeout + 1
                  mst.d('advanced time to', t[1])
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c2:get(true) == true)
                  mst.a(t[2] == 5)


                  -- advance => positive should be gone, negatives
                  -- should be refreshed
                  t[1] = t[1] + c2.positive_timeout - c2.negative_timeout 
                  mst.d('advanced time to', t[1])
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c2:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c2:get(true) == true)
                  mst.a(t[2] == 6)
                  
                  

                   end)
end)

describe("string_find_one", function ()
            it("t1", function ()
                  local s = 'foobar'
                  local p1 = '(o+)'
                  local p2 = '(z)'
                  local nop_fn = function ()  end
                  local fail_fn = function () error("should not match") end
                  mst.string_find_one(s, 
                                      p2,
                                      fail_fn,
                                      p1,
                                      function (x)
                                         mst.a(x == 'oo')
                                      end)
                   end)
end)
