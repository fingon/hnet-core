#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skvtool_core_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Feb 25 12:31:27 2013 mstenber
-- Last modified: Wed Jun 26 19:25:54 2013 mstenber
-- Edit time:     51 min
--


require "busted"
require "skvtool_core"
require "skv"
require 'mst_test'

lua2output = {
   {
      {}, '[]',
   },

   {
      {stringi='s',
       intti=1,
       booli=true},
      -- results should be in alphabetical order
      '{"booli":true,"intti":1,"stringi":"s"}',
   },
   {
      {[1]=1,
       [2]=2,
      },
      '[1,2]',
   },
}

describe("skvtool_core", function ()
            local s
            local stc
            local t
            local waited
            local updates
            before_each(function ()
                           updates = 0
                           s = skv.skv:new{long_lived=true, port=41245}
                           function s:set(k, v)
                              mst.d('dummy skv:set', k, v)
                              skv.skv.set(self, k, v)
                              updates = updates + 1
                           end
                           -- note: we can't ensure contents are same, as
                           -- json ordering is arbitrary. we COULD make sure
                           -- that with repr, results _are_ same as they're
                           -- always sorted.. but oh well, too lazy, for
                           -- now.
                           stc = skvtool_core.stc:new{skv=s,
                                                      encode_callback=mst.repr}
                           t = {}
                           waited = false
                           function stc:wait_in_sync()
                              self:empty_wcache()
                              waited = true
                           end
                           function stc:output(s)
                              table.insert(t, s)
                           end
                        end)
            after_each(function ()
                          s:done()
                       end)
            it("combines updates #combo", function ()
                  stc:process_keys{'foo=bar', 'foo=baz'}
                  -- has to be condensed
                  mst.a(updates == 1, 'should have only 1 update', updates)
                  mst.a(waited)

                  waited = false
                  updates = 0
                  -- make sure that doing say, add + add + remove + add results to only one real operation
                  stc:process_keys{'l+={"k":"v1"}',
                                   'l += {"k": "v2"}',
                                   'l -= {"k": "v2"}',
                                   'l += {"k": "v3"}',
                                  }
                  mst.a(updates == 1, 'should have only 1 update', updates)
                  mst.a(waited)
                  mst.a(#stc:get('l') == 2)


                                   
                   end)
            it("works", function ()
                  -- ok, let's test the basic functionality. 
                  
                  -- a) set
                  stc:process_keys{'foo=bar', 'bar="baz"'}
                  mst.a(#t == 0)
                  mst.a(waited)

                  -- b) get
                  stc:process_keys{'foo', 'bar'}
                  mst.a(#t == 2)
                  local rt = mst.repr(t)
                  local exp = '{"foo=\\"bar\\"", "bar=\\"baz\\""}'
                  mst.a(rt == exp, rt, exp)

                  -- c) list all
                  t = {}
                  stc:list_all()
                  local rt = mst.repr(t)
                  local exp = '{"bar=\\"baz\\"", "foo=\\"bar\\""}'
                  mst.a(rt == exp, rt, exp)

                  t = {}
                  stc:list_all(function (x)
                                  return x
                               end)
                  local rt = mst.repr(t)
                  local exp = '{"bar=baz", "foo=bar"}'
                  mst.a(rt == exp, rt, exp)

                   end)
            it("works sensibly with various inputs", function ()
                  -- check that lua => print output works
                  for i, v in ipairs(lua2output)
                  do
                     local luao, json = unpack(v)
                     t = {}
                     s:set('test', luao)
                     stc:process_key('test')
                     local exp = 'test=' .. mst.repr(luao)
                     mst.a(#t == 1)
                     mst_test.assert_repr_equal(t[1], exp)

                     -- make sure we can encode it also with json
                     -- encoder; however, we can't really check it's sanity
                     local s = stc:encode_value_to_string(luao, json.encode)
                     mst.a(s)
                  end
                  -- and inverse - set => lua
                  for i, v in ipairs(lua2output)
                  do
                     local luao, exps = unpack(v)
                     stc:process_keys{'test=' .. exps}
                     local v1 = s:get('test')
                     mst.a(mst.repr_equal(v1, luao), 'mismatch in lua2output', v1, luao)
                  end
                   end)
            it("fake prefix manipulation operations", function ()
                  stc:process_key('test += {"k":"x", "v":1}')
                  mst.a(not waited)
                  stc:process_key('test += {"k":"y", "v":2}')
                  mst.a(not waited)
                  -- now semantics do write only if requested, or at end of proces_keys
                  --mst.a(waited)
                  --waited = false
                  stc:process_key('test += {"k":"z", "v":3}')
                  local l = stc:get('test')
                  mst.a(l, 'no key at all')
                  mst.a(#l == 3)
                  mst.a(l[1].k == 'x')
                  stc:process_key('test -= {"k":"y"}')
                  local l = stc:get('test')
                  mst.a(#l == 2)
                  mst.a(l[1].k == 'x')
                  mst.a(l[2].k == 'z')
                   end)
             end)

