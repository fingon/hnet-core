#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_mst.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Wed Sep 19 16:38:56 2012 mstenber
-- Last modified: Wed Oct 16 15:47:11 2013 mstenber
-- Edit time:     281 min
--

require "busted"
require "mst"
require 'mst_test'
require "mst_skiplist"
require "mst_cache"
require "mst_eventful"
require "mst_cliargs"
require "dint"

module("mst_spec", package.seeall)

local ipi_skiplist = mst_skiplist.ipi_skiplist
local dummy_int = dint.dint

describe("ipi_skiplist", function ()
            function test_basic(enable_width)
               local width 
               if not enable_width
               then
                  width = false
               end
               local sl = ipi_skiplist:new{p=2, width=width}
               local d1 = dummy_int:new{v=5}
               local d2 = dummy_int:new{v=42}
               local d3 = dummy_int:new{v=1}
               local d4 = dummy_int:new{v=54}
               -- intentionally same!
               local d5 = dummy_int:new{v=1}
               sl:insert(d1)
               sl:insert(d2)
               sl:insert(d3)
               sl:insert(d4)
               -- make sure we're sane after unique values
               sl:sanity_check()
               -- and even after adding non-unique one
               sl:insert(d5)
               sl:sanity_check()
               mst.a(sl.c == 5)

               -- then, gradually remove each
               sl:remove(d3)
               sl:sanity_check()
               sl:remove(d5)
               sl:sanity_check()
               sl:remove(d4)
               sl:sanity_check()
               sl:remove(d2)
               sl:sanity_check()
               sl:remove(d1)
               sl:sanity_check()

            end
            it("works (width) #sl1w", function ()
                  test_basic(true)
                                      end)
            it("works #sl1", function ()
                  test_basic(false)
                             end)
            function test_random(enable_width)
               local width 
               local dup = 2
               local items = 100 
               if not enable_width
               then
                  width = false
               end
               local l = mst.array:new{}
               for j=1, dup
               do
                  for i=1, items
                  do
                     l:insert(dummy_int:new{v=i})
                  end
               end
               -- insert the first 100 items
               local sl = ipi_skiplist:new{p=2, width=width}
               for i, o in ipairs(mst.array_randlist(l))
               do
                  sl:insert(o)
                  if i % 10 == 0
                  then
                     sl:sanity_check()
                  end
               end
               mst.a(#sl.next > 1)
               mst.a(sl[sl.next[1]].v == 1)
               mst.a(sl:get_first().v == 1)
               sl:dump()
               sl:sanity_check()

               if enable_width
               then
                  -- make sure random access works
                  for i=1, items * dup
                  do
                     local o, err = sl:find_at_index(i)
                     mst.a(o, 'find failed while it should not', i, err)
                     mst.a(o.v == math.floor((i+1)/2), 
                           'find bugging', i, o)
                     local j = sl:find_index_of(o)
                     mst.a(i == j, 'different position than expected', i, j, o)
                  end
                  mst.a(not(sl:find_at_index(0)))
                  mst.a(not(sl:find_at_index(items * dup + 1)))
               end

               -- check we can iterate through it using iterate_while
               local calls = 0
               local prev = nil
               function f(o)
                  calls = calls + 1
                  mst.a(not prev or prev <= o, 
                        'order constraint not met', prev, o)
                  prev = o
                  return true
               end
               function g(o)
                  prev = o
                  calls = calls + 1
               end
               sl:iterate_while(f)
               mst.a(calls == items * dup)
               calls = 0
               sl:iterate_while(g)
               mst.a(calls == 1)
               mst.a(prev == sl:get_first())


               -- ok, next step is to remove the items, again
               -- in random order
               for i, o in ipairs(mst.array_randlist(l))
               do
                  sl:remove(o)
                  if i % 10 == 0
                  then
                     sl:sanity_check()
                  end
               end
               mst.a(sl.c == 0, 'structure not empty', sl)
               for i=1,#sl.next
               do
                  mst.a(not sl[sl:get_next_key(i)],
                        'something left on level', i)
               end
               sl:sanity_check()
            end
            it("worksish (width) #sl2w", function ()
                  mst.d_xpcall(function ()
                                  test_random(true)
                               end)
                                         end)

            it("worksish #sl2", function ()
                  test_random(false)
                                end)

                         end)

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
            it("can create subclasses #inh", function ()
                  local c1 = mst.create_class{class='c1'}

                  -- single inheritance (within class)
                  local c2 = mst.create_class({class='c2'}, c1)
                  c1.foo = true

                  mst.a(c2.foo, 'single inheritance fail')

                  -- multiple inheritance (within class)
                  local c3 = mst.create_class()
                  c2.bar = true
                  local c4 = mst.create_class(nil, c3, c2)
                  mst.a(c4.foo, 'multiple inheritance fail1')
                  mst.a(c4.bar, 'multiple inheritance fail2')

                                             end)
            
            it("has working cascading init/uninit", function ()
                  local function create_dummy_class(name)
                     local t = {false, false}
                     local c = mst.create_class{class=name,
                                                init=function ()
                                                   t[1] = true
                                                end,
                                                uninit=function ()
                                                   t[2] = true
                                                end}
                     return c, t
                  end
                  -- inheritance hierarchy:
                  -- c1 c2
                  --  \ /
                  --   c4
                  --   |
                  --   c5  c3
                  --    \ /
                  --     c6
                  local c1, s1 = create_dummy_class('c1')
                  local c2, s2 = create_dummy_class('c2')
                  local c3, s3 = create_dummy_class('c3')
                  local c4 = mst.create_class(nil, c1, c2)
                  local c5 = mst.create_class(nil, c4)
                  local c6 = mst.create_class(nil, c5, c3)
                  mst.a(not s1[1] and not s2[1] and not s3[1])
                  local i1 = c6:new()
                  mst.a(s1[1] and s2[1] and s3[1], 'init fail', s1, s2, s3)
                  mst.a(not s1[2] and not s2[2] and not s3[2])
                  i1:done()
                  mst.a(s1[2] and s2[2] and s3[2])
                  
                                                    end)

            it("can create class with args", function ()
                  local c = mst.create_class{mandatory={"foo"}}
                  assert.error(function ()
                                  local o1 = c:new()
                               end)
                  local o2 = c:new{foo=1}
                  assert.are.same(o2.foo, 1)
                  c.init = function (self)
                     self.bar = self.foo
                  end
                  local o3 = c:new{foo=2}
                  mst.a(o3.foo == 2)
                  mst.a(o3.bar == 2)

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
                  assert(t1.bar ~= t2.bar)
                  mst.a(mst.repr_equal(t1, t2))

                  local t1 = {foo={bar=2}, baz=3}
                  local t2 = mst.table_deep_copy(t1)
                  mst.a(mst.repr_equal(t1, t2), 'deep copy failure', t1, t2)

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

describe("debug_print", function ()
            it("works", function ()
                  local t = {'foo'}
                  mst.debug_print(function (...)

                                  end, t)
                  mst.a(getmetatable(t) == nil, 'metatable was set?!?')

                        end)
                        end)

describe("array_to_table", function ()
            it("works", function ()
                  local a = {1, 2, 3, 'z'}
                  local t = mst.array_to_table(a)
                  assert(t.z)
                        end)
                           end)

describe('string_split', function()
            it("works", function()
                  local ir = {
                     {{"foo:bar", ':'}, {"foo", "bar"}},
                     {{"foo:",  ':'}, {"foo", ""}},
                     {{":foo", ':'}, {"", "foo"}},
                     {{"foo:bar:baz", ':'}, {"foo", "bar", "baz"}},
                     {{"foo:bar:baz", ':', 1}, {"foo:bar:baz"}},
                     {{"foo:bar:baz", ':', 2}, {"foo", "bar:baz"}},
                     {{"foo:bar::baz", ':'}, {"foo", "bar", "", "baz"}},
                  }
                  for i, v in ipairs(ir)
                  do
                     local input, output = unpack(v)
                     local got = mst.repr(mst.string_split(unpack(input)))
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
            it("can be filtered for truish values", function ()
                  local a = mst.array:new{1,2,false,4}
                  mst.a(#a == 4)
                  mst.a(#a:filter() == 3)
                                                    end)
            it("can be reversed", function ()
                  -- make sure it works with even and odd # of entries

                  local a = mst.array:new{1,2,false,4}
                  a:reverse()
                  mst.a(mst.repr_equal(a, {4, false, 2, 1}), 'not same', a)

                  local a = mst.array:new{1,2,4}
                  a:reverse()
                  mst.a(mst.repr_equal(a, {4, 2, 1}), 'not same', a)

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
            it("setdefault", function ()
                  local m = mst.map:new{}
                  local foo = m:setdefault('foo', 'foo')
                  local foo2 = m:setdefault('foo', 'bar')
                  mst.a(foo == 'foo')
                  mst.a(foo2 == 'foo')
                  mst.a(m.foo == foo)

                  local m = mst.map:new{}
                  local foo = m:setdefault_lazy('foo', mst.map.new, mst.map)
                  mst.a(mst.map:is_instance(foo), 'wrong result', 
                        foo, mst.get_class(foo))
                  mst.a(m.foo == foo)
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
            local t
            local c
            before_each(function ()
                           t = {0, 0}
                           c = mst_cache.cache:new{get_callback=function (k)
                                                      t[2] = t[2] + 1
                                                      return k and true or nil
                                                                end}
                        end)
            it("works (positive+negative ttl with real time_callback)", function ()
                  -- re-initialize to use 'real' time (smirk)
                  c.time_callback=function ()
                     return t[1]
                  end
                  c.default_timeout = 1
                  c:clear()

                  -- test with defaults
                  mst.d('initial')

                  mst.a(c.items == 0)
                  mst.a(c:get('x') == true)
                  mst.a(c.items == 1)
                  mst.a(c:get('x') == true)
                  mst.a(c.items == 1)
                  mst.a(t[2] == 1, 'second call should be cached')

                  -- advance time 
                  t[1] = t[1] + c.default_timeout + 1
                  mst.d('advanced time to', t[1])
                  mst.a(c:get('x') == true)
                  mst.a(t[2] == 2, 'expired did not clear cache', t[2])
                  mst.a(c:get('x') == true)
                  mst.a(t[2] == 2, 'second call should be cached')

                  -- make sure positive/negative timeouts work if they're different
                  c.positive_timeout = 8
                  c.negative_timeout = 5
                  mst.a(c:get(false) == nil)
                  mst.a(c.items == 2)
                  mst.a(t[2] == 3)
                  mst.a(c:get(false) == nil)
                  mst.a(c.items == 2)
                  mst.a(t[2] == 3)
                  mst.a(c:get(true) == true)
                  mst.a(t[2] == 4)
                  mst.a(c:get(true) == true)
                  mst.a(t[2] == 4)

                  -- advance => negatives should be gone
                  t[1] = t[1] + c.negative_timeout + 1
                  mst.d('advanced time to', t[1])
                  mst.a(c:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c:get(true) == true)
                  mst.a(t[2] == 5)


                  -- advance => positive should be gone, negatives
                  -- should be refreshed
                  t[1] = t[1] + c.positive_timeout - c.negative_timeout 
                  mst.d('advanced time to', t[1])
                  mst.a(c:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c:get(false) == nil)
                  mst.a(t[2] == 5)
                  mst.a(c:get(true) == true)
                  mst.a(t[2] == 6)
                                                                        end)
            it("works (limited) #cachesize", function ()
                  c.max_items = 10
                  for i=1,100
                  do
                     c:get(i)
                  end
                  mst.a(t[2] == 100)
                  -- now, the clever part - last N/2 entries should be around
                  for i=96,100
                  do
                     c:get(i)
                  end
                  mst.a(t[2] == 100)
                  
                  mst.a(c.items > 0 and c.items <= c.max_items, 'wrong # items', c.items)
                  mst.a(c.items == mst.table_count(c.map))

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

describe("string misc", function ()
            it("endswith", function ()
                  mst.a(mst.string_endswith('foobar', 'bar'))
                  mst.a(not mst.string_endswith('fooba', 'bar'))
                           end)
            it("startswith", function ()
                  mst.a(mst.string_startswith('foobar', 'foo'))
                  mst.a(not mst.string_startswith('oobar', 'foo'))
                             end)
            it("strip", function ()
                  mst.a(mst.string_strip('foo ') == 'foo')
                  mst.a(mst.string_strip(' foo') == 'foo')
                  mst.a(mst.string_strip(' foo ') == 'foo')
                  mst.a(mst.string_strip(' foo\n') == 'foo')

                        end)
                        end)

describe("validity_sync", function ()
            it("it works with map", function ()
                  local m = mst.map:new{}
                  local o1 = {}
                  local o2 = {}
                  local o3 = {}
                  m.foo = o1
                  m.bar = o2
                  m.baz = o3
                  local vs = mst.validity_sync:new{t=m, single=true}
                  vs:clear_all_valid()
                  vs:set_valid(o1)
                  vs:set_valid(o2)
                  vs:remove_all_invalid()
                  mst.a(m:count() == 2)
                                    end)
            it("it works with array", function ()
                  local a = mst.array:new{}
                  local o1 = {}
                  local o2 = {}
                  local o3 = {}
                  a:insert(o1)
                  a:insert(o2)
                  a:insert(o3)
                  local vs = mst.validity_sync:new{t=a, single=true}
                  vs:clear_all_valid()
                  vs:set_valid(o1)
                  vs:set_valid(o2)
                  vs:remove_all_invalid()
                  mst.a(#a == 2)
                                      end)
            -- XXX - add test for non-single key validity stuff
                          end)

describe("count_all and friends #count", function ()
            describe("works", function ()
                        local c1 = mst.count_all_types(_G)
                        local c2 = mst.count_all_types(_G)

                        mst.d('got', c1)

                        local v = mst.debug_count_all_types_delta(c1, c2)
                        mst.a(v == 0)
                        local d = mst.array:new{}
                        local o1 = {foo=d}
                        local o2 = {foo=d, bar=d}
                        local o3 = {}

                        local c1 = mst.count_all_types(o1)
                        local c2 = mst.count_all_types(o2)
                        local v = mst.debug_count_all_types_delta(c1, c2)
                        mst.a(v == 0)
                        
                        local c3 = mst.count_all_types(o3)
                        mst.d('got c1', c1)
                        mst.d('got c3', c3)
                        mst.a(mst.table_count(c1) > 0)
                        mst.a(mst.table_count(c3) == 2) -- just total count + 1 table
                        local v = mst.debug_count_all_types_delta(c1, c3)
                        mst.a(v > 0)


                              end)
                                         end)

describe("d_xpcall", function ()
            it("works", function ()
                  mst.d_xpcall(function ()

                               end)
                        end)
                     end)

describe("string_to_hex", function ()
            it("works", function ()
                  local r = mst.string_to_hex('foo')
                  mst.a(#r == 6)
                        end)
                          end)

describe("hex_to_string", function ()
            it("works", function ()
                  local o = 'foo'
                  local h = mst.string_to_hex(o)
                  local o2 = mst.hex_to_string(h)
                  mst.a(o == o2, 'broken', o, o2, h)
                        end)
                          end)

describe("array_randlist", function ()
            it("works", function ()
                  local r = {1,2,3}
                  local ra = mst.array_randlist(r)
                  mst.a(#ra == 3)
                  mst.a(mst.array_find(ra, 1))
                  mst.a(mst.array_find(ra, 2))
                  mst.a(mst.array_find(ra, 3))
                  mst.a(not mst.array_find(ra, 4))
                        end)

                           end)

describe("array_unique", function ()
            it("works", function ()
                  local a1 = {1, 2, 3, 2, 1, 4}
                  mst_test.assert_repr_equal(mst.array_unique(a1), {1, 2, 3, 4})

                  mst_test.assert_repr_equal(mst.array_unique(), nil)

                        end)
                         end)

describe("hash_set", function ()
            it("works", function ()
                  mst.array.__eq = function (o1, o2)
                     return #o1 == #o2
                  end
                  local hs = mst.hash_set:new{hash_callback=
                                              function (f)
                                                 return 0
                                              end,
                                                                          equal_callback=
                                                                             function (o1, o2)
                                                                             return #o1 == #o2
                                                                             end}
                  local a1 = mst.array:new{1, 2, 3}
                  local a2 = mst.array:new{1, 2}
                  local a3 = mst.array:new{1, 2}
                  local a4 = mst.array:new{1}
                  hs:insert(a1)
                  hs:insert(a2)
                  mst.a(hs:get(a3) == a2)
                  mst.a(hs:get(a4) == nil)
                  mst.array.__eq = nil
                        end)
                     end)

describe("mst_eventful", function ()
            it("can create + connect events #ev",
               function ()
                  local c1 = mst_eventful.eventful:new_subclass{events={'foo'}, class='c1'}

                  local c2 = mst_eventful.eventful:new_subclass{class='c2'}
                  for i=1,2
                  do
                     local o1 = c1:new()
                     mst.a(o1.foo, 'event creation failed')
                     mst.a(not o1.foo:has_observers())
                     local o2 = c2:new()
                     local c3 = mst_eventful.eventful:new_subclass{class='c3',
                                                                   baz=function (self, v)
                                                                      self.got=v
                                                                   end}
                     local o3 = c3:new()
                     local got = {0}
                     o2:connect(o1.foo, 
                                function (v)
                                   mst.a(v == 'bar', v)
                                   got[1] = 1
                                end)
                     o3:connect_method(o1.foo, o3.baz)
                     mst.a(o1.foo:has_observers())
                     o1.foo('bar')
                     mst.a(got[1] == 1)
                     mst.a(o3.got == 'bar', 'o3.got=', o3.got)
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
                        o3:done()
                        -- observer should de-register itself 
                        mst.a(not o1.foo:has_observers())
                        o1:done()
                     end
                  end
               end)
            it("also can forward event -> event", function ()
                  local c1 = mst_eventful.eventful:new_subclass{events={'foo'}, class='c1'}

                  local c2 = mst_eventful.eventful:new_subclass{events={'bar'}, class='c2'}
                  local o1 = c1:new()
                  local o2 = c2:new()
                  o1:connect_event(o1.foo, o2.bar)
                  local got
                  o2:connect(o2.bar, 
                             function (v)
                                mst.a(v == 'bar', 'not bar', v)
                                got = true
                             end)
                  o1.foo('bar')
                  mst.a(got)
                                                  end)
                         end)

describe("table", function ()
            it("table_sorted_keys works", function ()
                  local t = {i=1, b=true, s='z'}
                  local keys = mst.table_sorted_keys(t)
                  mst_test.assert_repr_equal(keys, {'b', 'i', 's'})
                  local keys2 = {}
                  for k, v in mst.table_sorted_pairs(t)
                  do
                     table.insert(keys2, k)
                  end
                  mst_test.assert_repr_equal(keys2, {'b', 'i', 's'})
                                          end)
                  end)


describe("fake_callback", function ()
            it("works", function ()
                  local fc = mst_test.fake_callback
                  local o = fc:new()
                  o:set_array{
                     {
                        {'foo'}, 'bar'
                     }
                             }
                  local r = o('foo')
                  mst_test.assert_repr_equal(r, 'bar')
                  o:done()
                  local o = fc:new{skip=1, unpack_r=unpack}
                  o:set_array{
                     {
                        {'foo'}, {'bar'}
                     }
                             }
                  local r = o('xyzzy', 'foo')
                  mst_test.assert_repr_equal(r, 'bar')
                  o:done()

                        end)
                          end)

describe("mst_perf", function ()
            local c
            local r
            local p
            before_each(function ()
                           c = 0
                           r = 0
                           p = mst_test.perf_test:new{duration=0.01,
                                                      cb=function ()
                                                         c = c + 1
                                                      end}
                           function p:report_result()
                              r = r + 1
                           end
                        end)
            it("works", function ()
                  p:run()
                  mst.a(c > 0)
                  mst.a(r == 1)
                        end)
            it("works (verbose)", function ()
                  p.verbose = true
                  p:run()
                  mst.a(c > 0)
                  mst.a(r > 1)
                                  end)
                     end)

describe("iset #iset", function ()
            local data = {'foo', 'bar', 'baz'}
            local is
            local function sanity_random()
               local d = is:randitem()
               local found
               for i, v in ipairs(data)
               do
                  if v == d
                  then
                     found = true
                     --mst.a(i == idx, 'wrong index', v, i, idx)
                  end
               end
               mst.a(found, 'not found?!?', d)
               return d
            end
            before_each(function ()
                           is = mst.iset:new()
                           for i, v in ipairs(data)
                           do
                              is:insert(v)
                           end
                           mst_test.assert_repr_equal(is:count(), #data)

                        end)
            it("remove #isetr1", function ()
                  local d = sanity_random()
                  mst.d('removing (name)', d)
                  is:remove(d)
                  mst_test.assert_repr_equal(is:count(), #data - 1)
                  -- ugh, playing with internals, oh well
                  is:remove(is._array[1])
                  mst_test.assert_repr_equal(is:count(), #data - 2)
                  sanity_random()
                        end)
            it("remove nonradom", function ()
                  is:remove(data[1])
                  mst_test.assert_repr_equal(is._array, {'baz', 'bar'})
                  mst_test.assert_repr_equal(is['baz'], 1)
                  mst_test.assert_repr_equal(is['bar'], 2)
                  is:remove(data[2])
                  mst_test.assert_repr_equal(is._array, {'baz'})
                  mst_test.assert_repr_equal(is['baz'], 1)
                  mst_test.assert_repr_equal(is['bar'], nil)
                   end)
                 end)
