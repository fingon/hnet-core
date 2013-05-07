#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_tree_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue May  7 13:20:53 2013 mstenber
-- Last modified: Tue May  7 13:44:45 2013 mstenber
-- Edit time:     9 min
--

require 'busted'
require 'dns_tree'
require 'dns_db'

module('dns_tree_spec', package.seeall)

describe("dns_tree", function ()
            it("works", function ()
                  local root = dns_tree.node:new{label=''}
                  local p = {'foo', 'example', 'com'}
                  local v = 'bar'
                  local n = root:add_value(p, v)
                  mst.a(n)
                  local ll = n:get_ll()
                  local fqdn = n:get_fqdn()

                  mst.a(mst.repr_equal(p, ll), 'mismatch', p, ll)

                  local name = dns_db.ll2name(p)
                  mst.a(mst.repr_equal(name, fqdn), 'mismatch', name, fqdn)

                  mst.a(n:get_value() == v)
                  mst.a(n:get_default() == nil)

                  mst.a(root:get_value() == nil)
                  mst.a(root:get_default() == nil)

                  local v2 = root:match_ll(p)
                  mst.a(v2 == v)

                  local p2 = {'bar', 'example', 'com'}
                  local p2_sub = {'a', 'bar', 'example', 'com'}
                  local da = 'asdf'
                  local va = 'asdf2'
                  local n = root:add_value(p2, true)
                  function n:get_value(a)
                     return a
                  end
                  function n:get_default(a)
                     return a
                  end
                  mst.a(root:match_ll(p2, va) == va)
                  mst.a(root:match_ll(p2_sub, da) == da)
                   end)
end)
