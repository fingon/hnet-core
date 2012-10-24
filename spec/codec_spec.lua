#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: codec_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 cisco Systems, Inc.
--       All rights reserved
--
-- Created:       Thu Sep 27 18:34:49 2012 mstenber
-- Last modified: Fri Oct 19 13:00:26 2012 mstenber
-- Edit time:     15 min
--

require "busted"
require "codec"

module("codec_spec", package.seeall)

local tests = {
   -- check that different paddings work
   {codec.rhf_ac_tlv, {body=string.rep('1', 40)}},
   {codec.rhf_ac_tlv, {body=string.rep('1', 41)}},
   {codec.rhf_ac_tlv, {body=string.rep('1', 42)}},
   {codec.rhf_ac_tlv, {body=string.rep('1', 43)}},
   {codec.usp_ac_tlv, {prefix='dead::/16'}},
   {codec.asp_ac_tlv, {iid=3, prefix='dead::/16'}},
   {codec.asp_ac_tlv, {iid=3, prefix='dead:feed:dead:feed::/64'}},
}

describe("test the ac endecode",
         function ()
            it("basic en-decode ~= same #base", function ()
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
                     local l2 = codec.decode_ac_tlvs(b)
                     mst.a(#l2 == 1)
                     local r1 = mst.repr(l2[1])
                     local r2 = mst.repr(o2)
                     mst.a(r1 == r2, 'changed', r1, r2)
                     mst.a(mst.table_contains(o2, orig), "something missing", cl.class, o2, orig)
                  end
                                          end)
            it("can handle list of tlvs", function()
                  -- glom all tests together to one big thing
                  local l = mst.array_map(tests, function (s) 
                                             return s[1]:encode(s[2]) 
                                                 end)
                  local s = table.concat(l)
                  local l2 = codec.decode_ac_tlvs(s)
                  assert.are.same(#l, #l2)
                                          end)
         end)
