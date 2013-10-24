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
-- Last modified: Thu Oct 24 15:51:48 2013 mstenber
-- Edit time:     30 min
--

require 'busted'

local delsa = require('delsa').delsa
local dsm = require('dsm').dsm

local TEST_NODES=30
local TEST_ITERATIONS=100
local TEST_ADDITIONS_PER_ITERATION=20
local TEST_REMOVALS_PER_ITERATION=15
local ADVANCE_TIME_PER_ITERATION=10

dlinux_if = mst.create_class{class='dlinux_if', mandatory={'i'}}

function dlinux_if:get_if()
   local d = {}
   function d:get_hwaddr()
      return 'de:ad:be:ef:00:' .. tostring(self.i)
   end
   return d
end


function create_elsa_callback(o)
   local if_table = dlinux_if:new{i=o.i}
   local ep = elsa_pa.elsa_pa:new{elsa=o.sm.e, skv=o.skv, rid=o.rid,
                                  if_table=dlinux_if,
                                  time=o.time,
                                  pa_config={}}
   return ep
end

describe("elsa_pa N-node mutating topology", function ()
            local e, sm
            before_each(function ()
                           local iids = {}
                           local hwfs = {}
                           e = delsa:new{iid=iids, hwf=hwfs}
                           sm = dsm:new{e=e, port_offset=42420,
                                        create_callback=create_elsa_callback}
                           
                           for i=1,TEST_NODES
                           do
                              local name = 'node' .. tostring(i)
                              iids[name] = {{index=42, name='eth0'},
                                            {index=43, name='eth1'}}
                              hwfs[name] = name
                              local ep = sm:create_node{rid=name, i=i}
                              ep.originate_min_interval=0
                           end
                        end)
            after_each(function ()
                          sm:done()
                       end)

            local function ensure_sanity()
               local nl = sm:get_nodes()
               -- make sure each node has on each interface at most 1
               -- v6 and at most 1 v4 address (that is in assigned state)
               for i, ep in ipairs(nl)
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
                        local prev = h[lap.ifname]
                        mst.a(not prev, 'duplicate assigned lap found', prev, lap)
                        h[lap.ifname] = lap
                     else
                        -- there should never be address on non-assigned one!
                        --mst.a(not lap.address, 'an address detected!', lap)
                        -- historic one I _think_
                     end
                  end
               end
            end
            it("works #n", function ()
                  local nl = sm:get_nodes()
                  local n
                  -- iterations
                  for i=1,TEST_ITERATIONS
                  do
                     mst.d('elsa_pa_stress N - iteration', i, #nl, n)

                     local function mark_changed(rid)
                        -- _anyone_ connected to this should have
                        -- lsa_changed from this dude
                        for rid2, _ in pairs(e:get_connected(rid))
                        do
                           local o = e.nodes[rid2]
                           o:lsa_changed{rid=rid}
                        end
                     end

                     -- topology changes - add 
                     for j=1,TEST_ADDITIONS_PER_ITERATION
                     do
                        local src = mst.array_randitem(nl)
                        local srci = mst.randint(42, 43)
                        local dst = mst.array_randitem(nl)
                        local dsti = mst.randint(42, 43)
                        mark_changed(src.rid)
                        mark_changed(dst.rid)
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
                        local srcrid, srci, dstrid, dsti = unpack(o)
                        mark_changed(srcrid)
                        mark_changed(dstrid)
                        e:disconnect_neigh_one(unpack(o))
                     end

                     -- forcibly start at least once - because
                     -- we don't propagate the topology changes as lsa
                     -- changes
                     sm:run_nodes(3, nil, true)

                     ensure_sanity()
                     sm:advance_time(ADVANCE_TIME_PER_ITERATION)
                  end
                           end)

                                             end)
