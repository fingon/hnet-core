#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp_core_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed May  8 09:00:52 2013 mstenber
-- Last modified: Wed May  8 10:35:37 2013 mstenber
-- Edit time:     25 min
--

require 'busted'
require 'hp_core'

module('hp_core_spec', package.seeall)

function create_dummy_proxy(l1, l2)
   local hp = hp_core.hybrid_proxy:new{rid='rid1',
                                       domain={'foo', 'com'}}
   function hp:iterate_ap(f)
      for i, v in ipairs(l1)
      do
         f(v)
      end
   end

   function hp:iterate_usable_prefixes(f)
      for i, v in ipairs(l2)
      do
         f(v)
      end
   end
   return hp
end

local prefix_to_ll_material = {
   {'10.0.0.0/8', {'10', 'in-addr', 'arpa'}},
   {'dead::/16', {'d', 'a', 'e', 'd', 'ip6', 'arpa'}},
   {'dead:beef:cafe::/64', {
       '0', '0', '0', '0',
       'e', 'f', 'a', 'c',
       'f', 'e', 'e', 'b',
       'd', 'a', 'e', 'd', 'ip6', 'arpa'}},
}

describe("prefix_to_ll", function ()
            it("works", function ()
                  for i, v in ipairs(prefix_to_ll_material)
                  do
                     local p, exp_ll = unpack(v)
                     local ll = hp_core.prefix_to_ll(p)
                     mst.a(mst.repr_equal(ll, exp_ll),
                           'not equal', ll, exp_ll)
                  end
                   end)
             end)

local q_to_r_material = {
   {'bar.com', hp_core.RESULT_FORWARD_EXT},
   {'foo.com', nil},
   {'nonexistent.foo.com', hp_core.RESULT_NXDOMAIN},
   {'rid1.foo.com', nil},
   {'iid1.rid1.foo.com', nil},
   {'foo.iid1.rid1.foo.com', hp_core.RESULT_FORWARD_MDNS},
   {'11.in-addr.arpa', hp_core.RESULT_FORWARD_EXT},
   {'10.in-addr.arpa', nil},
   {'12.11.10.in-addr.arpa', nil},
   -- local 
   {'13.12.11.10.in-addr.arpa', hp_core.RESULT_FORWARD_MDNS},
   -- remote
   {'13.13.11.10.in-addr.arpa', hp_core.RESULT_FORWARD_INT},
   {'d.a.e.d.ip6.arpa', nil},
   {'d.ip6.arpa', hp_core.RESULT_FORWARD_EXT},
   -- local
   {'1.0.0.0.0.0.e.e.b.d.a.e.d.ip6.arpa', hp_core.RESULT_FORWARD_MDNS},
   -- remote
   {'1.0.0.0.0.1.e.e.b.d.a.e.d.ip6.arpa', hp_core.RESULT_FORWARD_INT},
}

describe("hybrid_proxy", function ()
            it("works", function ()
                  local hp = create_dummy_proxy(
                     {
                        {rid='rid1',
                         iid='iid1',
                         ip='1.2.3.4',
                         ifname='eth0',
                         prefix='dead:bee0::/48',
                        },
                        {rid='rid2',
                         iid='iid1',
                         ip='3.4.5.6',
                         prefix='dead:bee1::/48',
                        },
                        {rid='rid1',
                         iid='iid2',
                         ip='1.2.3.4',
                         ifname='eth1',
                         prefix='dead:beef::/48',
                        },
                        {rid='rid1',
                         iid='iid1',
                         ip='2.3.4.5',
                         ifname='eth0',
                         prefix='10.11.12.0/24',
                        },
                        {rid='rid2',
                         iid='iid1',
                         ip='3.4.5.6',
                         ifname='eth0',
                         prefix='10.11.13.0/24',
                        },

                     },
                     {
                        'dead::/16',
                        '10.0.0.0/8',
                     })
                  for i, v in ipairs(q_to_r_material)
                  do
                     local n, exp_r = unpack(v)
                     local q = {name=dns_db.name2ll(n)}
                     local r, err = hp:match{{qd={q}}}

                     mst.a(r == exp_r, 'result mismatch', n, exp_r, r, err)
                  end
                   end)
end)
