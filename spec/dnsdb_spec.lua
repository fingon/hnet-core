#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnsdb_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Dec 17 14:37:02 2012 mstenber
-- Last modified: Tue Jan  8 23:02:19 2013 mstenber
-- Edit time:     29 min
--

require "busted"
require "dnsdb"

module("dnsdb_spec", package.seeall)

-- first off, three records that are distinct (but shared, in mdns
-- terminology, due to lack of cache_flush)
local fake1 = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'foo', 'Bar'},
               rdata = 'foo',
}

local fake1case = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'Foo', 'bar'},
               rdata = 'foo',
}

local fake12 = mst.table_copy(fake1)
fake12.rdata = 'foo2'


local fake2 = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'foo2', 'Bar'}
}

-- then, yet another record, which overrides fake1+fake12, and has
-- cache_flush set.
local fakeu = {rclass = dnscodec.CLASS_IN,
               rtype = 42,
               name = {'foo', 'Bar'},
               rdata = 'foo',
               cache_flush = true,
}



describe("ns", function ()
            it("works", function ()
                  local ns = dnsdb.ns:new{enable_copy=true}
                  -- add two items (one twice, just to make sure it
                  -- doesn't get added again)
                  mst.a(ns:count() == 0)
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake1case)
                  mst.a(ns:count() == 1, 'same record => not 1? problem')
                  ns:insert_rr(fake12)
                  mst.a(ns:count() == 2, 'different rdata => same? problem', ns:count())
                  ns:insert_rr(fake2)
                  mst.a(ns:count() == 3)

                  -- test that we can also find fake1 based on synthetic entry
                  local s = {name = fake1.name, rtype = fake1.rtype, rdata=fake1.rdata}
                  local o = ns:find_rr(s)
                  mst.a(o and o:equals(fake1))

                  -- make sure that removing items works too

                  -- (note: fake1 is used as-is in the db due to
                  -- disabled autocopy, but fake2 _isn't_, the insert
                  -- creates new copy. still, use of 'same' named
                  -- object should work!)
                  ns:remove_rr(fake1)
                  ns:remove_rr(fake12)
                  ns:remove_rr(fake2)
                  mst.a(ns:count() == 0)

                   end)

            it("mdns features work #mdns", function ()
                  -- second iteration; add fake1+fake12+, and then override
                  -- them with fakeu => as a result, should have only 1
                  -- entry
                  local ns = dnsdb.ns:new{enable_copy=true}
                  ns:insert_rr(fake1)
                  ns:insert_rr(fake12)
                  mst.a(ns:count() == 2, 
                        'different rdata => same? problem',
                        ns:count())
                  ns:insert_rr(fake2)
                  mst.a(ns:count() == 3)

                  -- then, add the fakeu => should have just one entry
                  ns:insert_rr(fakeu)
                  
                  mst.a(ns:count() == 2, ns)
                  local s = mst.table_copy(fakeu)
                  local o = ns:find_rr(s)
                  mst.a(o and o:equals(fakeu))
                  ns:remove_rr(fakeu)
                  ns:remove_rr(fake2)
                  mst.a(ns:count() == 0)

                   end)
end)
