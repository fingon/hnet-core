#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: codec_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Sep 27 18:34:49 2012 mstenber
-- Last modified: Thu Sep 27 19:24:15 2012 mstenber
-- Edit time:     5 min
--

require "luacov"
require "busted"
require "codec"

describe("test the ac endecode",
         function ()
            it("basic en-decode ~= same", function ()
                  local tests = {
                     {codec.rhf_ac_tlv, {body=string.rep('1', 40)}},
                     {codec.usp_ac_tlv, {prefix='dead::/16'}},
                     {codec.asp_ac_tlv, {iid=3, prefix='dead::/16'}},
                  }
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

                     mst.a(mst.table_contains(o2, orig), "something missing", cl.class, o2, orig)
                  end
                                          end)
         end)
