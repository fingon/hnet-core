#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa_stress.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Nov 13 16:04:01 2012 mstenber
-- Last modified: Tue Nov 13 16:46:34 2012 mstenber
-- Edit time:     6 min
--

require 'busted'

local delsa = require('delsa').delsa
local dsm = require('dsm').dsm

local TEST_NODES=30
local TEST_ITERATIONS=100
local TEST_ADDITIONS_PER_ITERATION=20
local TEST_REMOVALS_PER_ITERATION=15
local ADVANCE_TIME_PER_ITERATION=10

describe("elsa_pa N-node mutating topology", function ()
            local e, sm
            before_each(function ()
                           local iids = {}
                           local hwfs = {}
                           e = delsa:new{iid=iids, hwf=hwfs}
                           sm = dsm:new{e=e, port_offset=42420}
                           
                           for i=1,TEST_NODES
                           do
                              local name = 'node' .. tostring(i)
                              iids[name] = {{index=42, name='eth0'},
                                            {index=43, name='eth1'}}
                              hwfs[name] = name
                              local ep = sm:add_router(name)
                              ep.originate_min_interval=0
                           end
                        end)
            after_each(function ()
                          sm:done()
                       end)

            local function ensure_sanity()
               -- make sure each node has on each interface at most 1
               -- v6 and at most 1 v4 address (that is in assigned state)
               for i, ep in ipairs(sm.eps)
               do
                  local found_v4 = {}
                  local found_v6 = {}
                  for i, lap in ipairs(ep.pa.lap:values())
                  do
                     if lap.assigned
                     then
                        local h
                        if lap.prefix:is_ipv4()
                        then
                           h = found_v4
                        else
                           h = found_v6
                        end
                        mst.a(not h[lap.ifname])
                        h[lap.ifname] = true
                     else
                        -- there should never be address on non-assigned one!
                        mst.a(not lap.address)
                     end
                  end
               end
            end
            it("works #n", function ()
                  local n
                  -- iterations
                  for i=1,TEST_ITERATIONS
                  do
                     mst.d('elsa_pa_stress N - iteration', i, #sm.eps, n)

                     -- topology changes - add 
                     for j=1,TEST_ADDITIONS_PER_ITERATION
                     do
                        local src = mst.array_randitem(sm.eps)
                        local srci = mst.randint(42, 43)
                        local dst = mst.array_randitem(sm.eps)
                        local dsti = mst.randint(42, 43)
                        e:connect_neigh_one(src.rid, srci, dst.rid, dsti)
                     end
                     -- gather set of _all_ links
                     local conns = e:get_flat_list()
                     n = #conns
                     mst.a(#conns > 0)

                     -- and remove some (duplicates do not matter)
                     for k=1,TEST_REMOVALS_PER_ITERATION
                     do
                        local o = mst.array_randitem(conns)
                        e:disconnect_neigh_one(unpack(o))
                     end

                     sm:run_nodes(3, true)

                     ensure_sanity()
                     sm:advance_time(ADVANCE_TIME_PER_ITERATION)
                  end
                           end)

                                             end)
