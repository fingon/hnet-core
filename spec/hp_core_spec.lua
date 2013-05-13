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
-- Last modified: Mon May 13 17:49:31 2013 mstenber
-- Edit time:     92 min
--

require 'busted'
require 'hp_core'
require 'scr'

module('hp_core_spec', package.seeall)

local DOMAIN_LL={'foo', 'com'}

local prefix_to_ll_material = {
   {'10.0.0.0/8', {'10', 'in-addr', 'arpa'}},
   {'dead::/16', {'d', 'a', 'e', 'd', 'ip6', 'arpa'}},
   {'dead:beef:cafe::/64', {
       '0', '0', '0', '0',
       'e', 'f', 'a', 'c',
       'f', 'e', 'e', 'b',
       'd', 'a', 'e', 'd', 'ip6', 'arpa'}},
}

local dns_q_to_mdns_material = {
   {
      {name={'x', 'foo', 'com'}},
      {name={'x', 'local'}},
   },
   -- in6/in-addr.arpa should pass as-is (used for reverse resolution)
   {
      {name={'x', 'in-addr', 'arpa'}},
      {name={'x', 'in-addr', 'arpa'}},
   },
   {
      {name={'x', 'ip6', 'arpa'}},
      {name={'x', 'ip6', 'arpa'}},
   },
   -- but dummy arpa should not!
   {
      {name={'x', 'arpa'}},
      nil,
   },
   -- other domains should also fail
   {
      {name={'foo', 'com'}},
      nil,
   },
   {
      {name={'y', 'bar', 'com'}},
      nil,
   },
   {
      {name={'baz'}},
      nil,
   },
}

local dns_dummy_q = {name={'name', 'foo', 'com'},
                     qtype=dns_const.TYPE_ANY,
                     qclass=dns_const.CLASS_ANY}

local mdns_rrs_to_dns_reply_material = {
   -- nothing found => name error
   {{},
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NAME_ERROR}, 
     qd={dns_dummy_q},
     an={}, ar={}, 
    },
   },
   
   -- nothing _matching_ found => name error
   {{
       -- one fake-RR, but with wrong name
       {name={'blarg', 'local'}},
    },
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NAME_ERROR}, 
     qd={dns_dummy_q},
     an={}, ar={}, 
    },
   },

   -- normal case - match
   {{
       -- matching one
       {name={'name', 'local'}},
       -- additional record one
       {name={'blarg', 'local'}},
    },
    {h={id=123, qr=true, ra=true}, 
     qd={dns_dummy_q},
     an={{name={'name', 'foo', 'com'}}}, 
     ar={{name={'blarg', 'foo', 'com'}}}, 
    },
   },

   -- check that PTR and SRV work as advertised
   {{
       -- matching one
       {name={'name', 'local'}, rtype=dns_const.TYPE_PTR,
        rdata_ptr={'x', 'local'}},
       -- additional record one
       {name={'blarg', 'local'}, rtype=dns_const.TYPE_SRV,
        rdata_srv={target={'y', 'local'}}},
    },
    {h={id=123, qr=true, ra=true}, 
     qd={dns_dummy_q},
     an={{name={'name', 'foo', 'com'}, rtype=dns_const.TYPE_PTR,
          rdata_ptr={'x', 'foo', 'com'}}}, 
     ar={{name={'blarg', 'foo', 'com'}, rtype=dns_const.TYPE_SRV,
          rdata_srv={target={'y', 'foo', 'com'}}}}, 
    },
   },

   -- check that no rewriting happens for arpa stuff (provide
   -- additional record with arpa name, and main record with field
   -- with arpa name)
   {{
       -- matching one
       {name={'name', 'local'}, rtype=dns_const.TYPE_PTR,
        rdata_ptr={'x', 'ip6', 'arpa'}},
       -- additional record one
       {name={'blarg', 'in-addr', 'arpa'}, rtype=dns_const.TYPE_SRV,
        rdata_srv={target={'y', 'local'}}},
    },
    {h={id=123, qr=true, ra=true}, 
     qd={dns_dummy_q},
     an={{name={'name', 'foo', 'com'}, rtype=dns_const.TYPE_PTR,
          rdata_ptr={'x', 'ip6', 'arpa'}}}, 
     ar={{name={'blarg', 'in-addr', 'arpa'}, rtype=dns_const.TYPE_SRV,
          rdata_srv={target={'y', 'foo', 'com'}}}}, 
    },
   },


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

function create_fake_callback()
   local a = {1}
   function f(...)
      a[1] = a[1] + 1
      mst.a(#a >= i, 'out of bytes')
      local got = {...}
      local exp, r = unpack(a[a[1]])
      mst.a(mst.repr_equal(got, exp), 
            'non-expected input - exp/got', exp, got)
      return r
   end
   return f, a
end

function assert_fake_callback_done(a)
   mst.a(#a>0, 'invalid a', a)
   mst.a(a[1] == #a, 'something not consumed?', a)
end

function test_list(a, f)
   for i, v in ipairs(a)
   do
      local input, output = unpack(v)

      -- then call test function
      local result, err = f(input)

      -- and make sure that (repr-wise) result is correct
      mst.a(mst.repr_equal(result, output), 
            'not same - exp/got', 
            output, result, err,
           'for',
           input)
   end
end

describe("hybrid_proxy", function ()
            local hp
            local canned_mdns
            local l1, l2, l3, l4
            before_each(function ()
                           local f, g
                           f, l3 = create_fake_callback()
                           g, l4 = create_fake_callback()
                           
                           hp = hp_core.hybrid_proxy:new{rid='rid1',
                                                         domain=DOMAIN_LL,
                                                         mdns_resolve_callback=f,
                                                        }
                           l1 = {
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

                              }
                           l2 = 
                              {
                                 'dead::/16',
                                 '10.0.0.0/8',
                              }
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
                           function hp:forward(server, req)
                              return g(server, req)
                           end
                        end)
            after_each(function ()
                          hp:done()
                          hp = nil

                          -- shouldn't have scr running anyway, we use only
                          -- in-system state

                          --mst.a(scr.clear_scr())
                          assert_fake_callback_done(l3)
                          assert_fake_callback_done(l4)

                       end)
            it("match works (correct decisions on various addrs)", function ()
                  test_list(q_to_r_material,
                            function (n)
                               local q = {name=dns_db.name2ll(n)}
                               local r, err = hp:match{{qd={q}}}
                               return r
                            end)
                        end)
            it("dns req->mdns q conversion works #d2m", function ()
                  test_list(dns_q_to_mdns_material,
                            function (q)
                               local req = {qd={q}}
                               local r, err = hp:rewrite_dns_req_to_mdns_q(req, DOMAIN_LL)
                               return r
                            end)
                   end)
            it("mdns->dns conversion works", function ()
                  local req = {
                     h={id=123},
                     qd={
                        dns_dummy_q,
                     }
                  }
                  local q, err = hp:rewrite_dns_req_to_mdns_q(req, DOMAIN_LL)
                  mst.a(q)
                  test_list(mdns_rrs_to_dns_reply_material,
                            function (rrs)
                               return hp:rewrite_rrs_from_mdns_to_reply_msg(req, q, rrs, DOMAIN_LL)
                            end)
                   end)
            it("dns->mdns->reply flow works", function ()
                  -- these are most likely the most complex samples -
                  -- full message interaction 
                  
                  -- we use l3/l4 to populate mdns/dns interactions,
                  -- respectively


                  

                   end)
                         end)
