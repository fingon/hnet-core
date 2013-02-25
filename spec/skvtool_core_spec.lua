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
-- Last modified: Mon Feb 25 15:00:40 2013 mstenber
-- Edit time:     26 min
--


require "busted"
require "skvtool_core"
require "skv"

lua2output = {
   {
      {}, '[]',
   },

   {
      {stringi='s',
       intti=1,
       booli=true},
      '{"intti":1,"stringi":"s","booli":true}',
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
            before_each(function ()
                           s = skv.skv:new{long_lived=true, port=41245}
                           stc = skvtool_core.stc:new{skv=s}
                           t = {}
                           waited = false
                           function stc:wait_in_sync()
                              waited = true
                           end
                           function stc:output(s)
                              table.insert(t, s)
                           end
                        end)
            after_each(function ()
                          s:done()
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
                     local luao, exps = unpack(v)
                     t = {}
                     s:set('test', luao)
                     stc:process_key('test')
                     local exp = 'test=' .. exps
                     mst.a(#t == 1)

                     mst.a(t[1] == exp, 'mismatch', exp, t[1])
                  end
                  -- and inverse - set => lua
                  for i, v in ipairs(lua2output)
                  do
                     local luao, exps = unpack(v)
                     stc:process_key('test=' .. exps)
                     mst.a(mst.repr_equal(s:get('test'), luao))
                  end
                   end)
            it("fake prefix manipulation operations", function ()
                  stc:process_key('test += {"k":"x", "v":1}')
                  mst.a(not waited)
                  stc:process_key('test += {"k":"y", "v":2}')
                  mst.a(waited)
                  waited = false
                  stc:process_key('test += {"k":"z", "v":3}')
                  local l = s:get('test')
                  mst.a(l, 'no key at all')
                  mst.a(#l == 3)
                  mst.a(l[1].k == 'x')
                  stc:process_key('test -= {"k":"y"}')
                  local l = s:get('test')
                  mst.a(#l == 2)
                  mst.a(l[1].k == 'x')
                  mst.a(l[2].k == 'z')
                   end)
             end)

