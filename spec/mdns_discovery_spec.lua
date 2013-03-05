#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_discovery_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Mar  5 12:23:43 2013 mstenber
-- Last modified: Tue Mar  5 12:46:17 2013 mstenber
-- Edit time:     12 min
--

-- This is a testsuite for mdns discovery
require "busted"
require "delsa"
require "dsm"
require "mdns_discovery"

local _dsm = dsm.dsm
local _delsa = delsa.delsa
local _md = mdns_discovery.mdns_discovery

SD_ROOT = mdns_discovery.SD_ROOT
FOO_SERVICE = {'foo', 'local'}
FOO_INSTANCE = {'foo', 'bar', 'local'}

describe("mdns_discovery", function ()
            local e
            local dsm
            local md
            local qs
            before_each(function ()
                           e = _delsa:new{hwf={}}
                           dsm = _dsm:new{e=e, 
                                          port_offset=true,
                                          create_callback=true}
                           -- port_offset/create_callback only
                           -- needed with create_node; we use add_node
                           -- instead 
                           qs = {}
                           md = _md:new{rid='x',
                                        query=function (q)
                                           table.insert(qs, q)
                                              end,
                                        time=function ()
                                           return dsm.t
                                        end,
                                       }
                           dsm:add_node(md)
                        end)
            it("works (nobody on the network)", function ()
                  dsm:run_nodes(123)
                  mst.a(#qs == 1)
                  mst.a(qs[1].name == SD_ROOT)
                  dsm:run_nodes_until_delta(123, mdns_discovery.REDUNDANT_FREQUENCY+10)
                  mst.a(#qs == 2)
                  mst.a(mst.repr_equal(qs[1], qs[2]))
                   end)

            it("works (someone on the network)", function ()
                  dsm:run_nodes(123)
                  mst.a(#qs == 1)
                  qs = {}

                  -- now, pretend we got a reply!
                  local foo_service_rr = {
                     name=SD_ROOT,
                     rtype=dns_const.TYPE_PTR,
                     rclass=dns_const.CLASS_IN,
                     rdata_ptr=FOO_SERVICE,
                  }
                  md:cache_changed_rr(foo_service_rr, true)
                  dsm:run_nodes(123)
                  mst.a(#qs == 1)
                  mst.a(qs[1].name == FOO_SERVICE)
                  qs = {}

                  -- make sure we get now two replies, as next time we
                  -- should query both
                  dsm:run_nodes_until_delta(123, mdns_discovery.REDUNDANT_FREQUENCY+10)
                  mst.a(#qs == 2)
                  qs = {}

                  -- then, once we remove the rr, should get only one
                  md:cache_changed_rr(foo_service_rr)
                  dsm:run_nodes_until_delta(123, mdns_discovery.REDUNDANT_FREQUENCY+10)
                  mst.a(#qs == 1)
                  qs = {}
                  


                   end)

end)
