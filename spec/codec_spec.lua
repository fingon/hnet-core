#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: codec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Sat Oct 19 00:28:57 2013 mstenber
-- Last modified: Sat Oct 19 00:32:00 2013 mstenber
-- Edit time:     3 min
--

require "busted"
require "codec"
require 'mst_test'

describe("u16 <> nb", function ()
            it("works", function ()
                  local v1 = 42
                  local b = codec.u16_to_nb(42)
                  local v2 = codec.nb_to_u16(b)
                  local b2 = 'xx' .. b
                  mst_test.assert_repr_equal(v1, v2)
                  mst_test.assert_repr_equal(b, string.char(0) .. 
                                             string.char(42))
                  local v3 = codec.nb_to_u16(b2, 3)
                  mst_test.assert_repr_equal(v3, v1)

                        end)
end)
