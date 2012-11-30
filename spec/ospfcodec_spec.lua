#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ospfcodec_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Sep 27 18:34:49 2012 mstenber
-- Last modified: Fri Nov 30 11:10:12 2012 mstenber
-- Edit time:     23 min
--

require "busted"
require "ospfcodec"

module("ospfcodec_spec", package.seeall)

local tests = {
   -- check that different paddings work
   {ospfcodec.rhf_ac_tlv, {body=string.rep('1', 40)}},
   {ospfcodec.rhf_ac_tlv, {body=string.rep('1', 41)}},
   {ospfcodec.rhf_ac_tlv, {body=string.rep('1', 42)}},
   {ospfcodec.rhf_ac_tlv, {body=string.rep('1', 43)}},
   {ospfcodec.usp_ac_tlv, {prefix='dead::/16'}},
   {ospfcodec.usp_ac_tlv, {prefix='10.0.0.0/8'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='dead::/16'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='8000::/1'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='::/1'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='::/1'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='1.2.3.0/24'}},
   {ospfcodec.asp_ac_tlv, {iid=3, prefix='dead:feed:dead:feed::/64'}},
   {ospfcodec.json_ac_tlv, {table={foo='bar'}}},
   {ospfcodec.json_ac_tlv, {table={'foo'}}},
   {ospfcodec.json_ac_tlv, {table={'foo'}}},
}

describe("test the ac endecode",
         function ()
            setup(function ()
                     -- make sure the classes do copies of the encoded
                     -- dictionaries, we don't want to copy test vectors
                     -- by hand
                     for i, v in ipairs(tests)
                     do
                        local cl, orig = unpack(v)
                        cl.copy_on_encode = true
                     end
                  end)
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
                     local l2 = ospfcodec.decode_ac_tlvs(b)
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
                  local l2 = ospfcodec.decode_ac_tlvs(s)
                  assert.are.same(#l, #l2)
                                          end)
         end)

describe("make sure stuff is in network order", function ()
            it("works", function ()
                  local r = ospfcodec.json_ac_tlv:encode{table={'foo'}}
                  local _null = string.char(0)
                  local c = string.sub(r, 1, 1)
                  local b = string.byte(c)
                  mst.a(c == _null, 'wierd first character', b)
                  mst.a(string.sub(r, 3, 3) == _null)
                   end)
end)
