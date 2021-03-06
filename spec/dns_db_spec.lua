#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_db_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 14:37:02 2012 mstenber
-- Last modified: Mon Nov  4 14:57:54 2013 mstenber
-- Edit time:     56 min
--

require "busted"
require "dns_db"
require "mst_test"

module("dns_db_spec", package.seeall)

-- first off, three records that are distinct (but shared, in mdns
-- terminology, due to lack of cache_flush)
local fake1 = {rclass = dns_const.CLASS_IN,
               rtype = 42,
               name = {'foo', 'Bar'},
               rdata = 'foo',
}

local fake1case = {rclass = dns_const.CLASS_IN,
               rtype = 42,
               name = {'Foo', 'bar'},
               rdata = 'foo',
}

local fake12 = mst.table_copy(fake1)
fake12.rdata = 'foo2'


local fake2 = {rclass = dns_const.CLASS_IN,
               rtype = 42,
               name = {'foo2', 'Bar'}
}

-- then, yet another record, which overrides fake1+fake12, and has
-- cache_flush set.
local fakeu = {rclass = dns_const.CLASS_IN,
               rtype = 42,
               name = {'foo', 'Bar'},
               rdata = 'foo',
               cache_flush = true,
}

-- assorted examples of valid rtyped rrs

local ptr1 = {rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_PTR,
              name={'dummyptr1', 'y'},
              rdata_ptr={'z', '1'}
}

local ptr2 = {rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_PTR,
              name={'dummyptr2', 'y', 'z'},
              rdata_ptr={'z1', '2'}
}


local srv1 = {rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_SRV,
              name={'dummysrv1', 'y'},
              rdata_srv={port=1, priority=0, target={'target', 'y'}, weight=0},
}

local srv2 = {rclass=dns_const.CLASS_IN,
              rtype=dns_const.TYPE_SRV,
              name={'dummysrv2', 'y'},
              rdata_srv={port=1, priority=0, target={'target2', 'y'}, weight=0},
}

local a1 = {rclass=dns_const.CLASS_IN,
            rtype=dns_const.TYPE_A,
            name={'dummya', 'y'},
            rdata_a='1.2.3.4',
}

local aaaa1 = {rclass=dns_const.CLASS_IN,
            rtype=dns_const.TYPE_AAAA,
            name={'dummya', 'y'},
            rdata_aaaa='dead:beef::1',
}


local nsec1 = {rclass=dns_const.CLASS_IN,
            rtype=dns_const.TYPE_NSEC,
            name={'dummya', 'y'},
            rdata_nsec={bits={1,2,3,42,280}},
}

local all_rrs = {ptr1, ptr2, srv1, srv2, a1, aaaa1, nsec1}

describe("ll<>name functions", function ()
            it("ll2nameish", function ()
                  for i, v in ipairs{
                     {{'foo', 'bar'}, 'foo.bar'},
                     {{'foo.bar', 'baz'}, {'foo.bar', 'baz'}}
                                    }
                  do
                     local l, n = unpack(v)
                     local r = dns_db.ll2nameish(l)
                     mst.a(mst.repr_equal(n, r), 'll2nameish fail', r, n)
                  end
                   end)
             end)


describe("ns", function ()
            it("works", function ()
                  local ns = dns_db.ns:new{enable_copy=true}
                  local ecalls = 0 -- empty
                  ns:connect(ns.is_empty, function ()
                                ecalls = ecalls + 1
                                          end)
                  local ncalls = 0 -- non-empty
                  ns:connect(ns.is_not_empty, function ()
                                ncalls = ncalls + 1
                                          end)

                  -- add two items (one twice, just to make sure it
                  -- doesn't get added again)
                  mst_test.assert_repr_equal(ecalls, 0)
                  mst_test.assert_repr_equal(ncalls, 0)

                  mst.a(ns:count() == 0)
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake1case)
                  mst.a(ns:count() == 1, 'same record => not 1? problem')
                  ns:insert_rr(fake12)
                  mst.a(ns:count() == 2, 'different rdata => same? problem', ns:count())
                  ns:insert_rr(fake2)
                  mst.a(ns:count() == 3)

                  mst_test.assert_repr_equal(ecalls, 0)
                  mst_test.assert_repr_equal(ncalls, 1)

                  -- test that we can also find fake1 based on synthetic entry
                  local s = {name = fake1.name, rtype = fake1.rtype, rdata=fake1.rdata}
                  local o = ns:find_rr(s)
                  mst.a(o and o:equals(fake1))

                  local l = ns:find_rr_list(s)
                  mst_test.assert_repr_equal(l, {o}, 'find_rr_list bug')

                  local s = {name = fake1.name, rtype=fake1.rtype}
                  local l = ns:find_rr_list(s)
                  -- should get fake1 + fake12
                  mst_test.assert_repr_equal(#l, 2, 'find_rr_list bug')


                  -- make sure that removing items works too

                  -- (note: fake1 is used as-is in the db due to
                  -- disabled autocopy, but fake2 _isn't_, the insert
                  -- creates new copy. still, use of 'same' named
                  -- object should work!)
                  ns:remove_rr(fake1)
                  ns:remove_rr(fake12)
                  ns:remove_rr(fake2)

                  mst.a(ns:count() == 0)

                  mst_test.assert_repr_equal(ecalls, 1)
                  mst_test.assert_repr_equal(ncalls, 1)

                   end)

            it("mdns features work #mdns", function ()
                  -- second iteration; add fake1+fake12+, and then override
                  -- them with fakeu => as a result, should have only 1
                  -- entry
                  local ns = dns_db.ns:new{enable_copy=true}
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake12)
                  mst.a(ns:count() == 2, 
                        'different rdata => same? problem',
                        ns:count())
                  ns:insert_rr(fake2)
                  mst.a(ns:count() == 3)

                  ns:insert_rrs{fakeu}
                  
                  local cnt = ns:count() 
                  mst.a(cnt == 2, 'count not 2', cnt, ns)
                  local s = mst.table_copy(fakeu)
                  local o = ns:find_rr(s)
                  mst.a(o and o:equals(fakeu))
                  ns:remove_rr(fakeu)
                  ns:remove_rr(fake2)
                  mst.a(ns:count() == 0)

                   end)

            it("has robust deduplication", function ()
                  local ns = dns_db.ns:new{enable_copy=true}
                  for _, rr in ipairs(all_rrs)
                  do
                     ns:insert_rr(mst.table_deep_copy(rr))
                     ns:insert_rr(mst.table_deep_copy(rr))
                  end
                  mst.a(ns:count() == #all_rrs)
                  for _, rr in ipairs(all_rrs)
                  do
                     ns:remove_rr(rr)
                  end
                  mst.a(ns:count() == 0)
                   end)
            it("handles removal of bunch of entries correctly", function ()
                  local ns = dns_db.ns:new{enable_copy=true}
                  local n = 100
                  for i=1,n
                  do
                     ns:insert_rr{rtype=42, rclass=1, name={'foo'}, rdata=i}
                  end
                  local ic = 0
                  ns:iterate_rrs_for_ll_safe({'foo'},
                                             function (rr)
                                                ic = ic + 1
                                                local orr = ns:find_rr(rr)
                                                mst.a(orr)
                                                ns:remove_rr(orr)
                                             end)
                  local cnt = ns:count()
                  mst.a(ic == n, 'iterate did not go through all', ic, n)
                  mst.a(cnt == 0, 'iterate+find+remove broken', cnt)

                   end)
end)
