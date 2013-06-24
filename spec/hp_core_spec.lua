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
-- Last modified: Mon Jun 24 11:31:13 2013 mstenber
-- Edit time:     359 min
--

require 'busted'
require 'hp_core'
require 'scr'
require 'dns_channel'
local _t = require 'mst_test'
module('hp_core_spec', package.seeall)

local DOMAIN_LL={'foo', 'com'}
local DOMAIN_SUFFIX='.foo.com'
local TEST_SRC='4.3.2.1'
local TEST_ID=123
local OTHER_IP='3.4.5.6'

local RP = hp_core.RIDPREFIX
local IP = hp_core.IIDPREFIX

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
   -- 1 nothing found => name error
   {{},
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN}, 
     qd={dns_dummy_q},
     an={}, ar={}, 
    },
   },
   
   -- 2 nothing _matching_ found => name error
   {{
       -- one fake-RR, but with wrong name
       {name={'blarg', 'local'}},
    },
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN}, 
     qd={dns_dummy_q},
     an={}, ar={}, 
    },
   },

   -- 3 normal case - match
   {{
       -- matching ones
       {name={'name', 'local'}, cache_flush=true,
        rtype=dns_const.TYPE_A, rdata_a='1.2.3.4'},
       {name={'name', 'local'}, cache_flush=true,
        rtype=dns_const.TYPE_AAAA, rdata_aaaa='dead::1'},
       -- v6 linklocal should be omitted
       {name={'name', 'local'}, cache_flush=true,
        rtype=dns_const.TYPE_AAAA, rdata_aaaa='fe80::1'},
       -- additional record one
       {name={'blarg', 'local'}},
    },
    {h={id=123, qr=true, ra=true}, 
     qd={dns_dummy_q},
     an={{name={'name', 'foo', 'com'}, 
          rtype=dns_const.TYPE_A, rdata_a='1.2.3.4'},
         {name={'name', 'foo', 'com'}, 
          rtype=dns_const.TYPE_AAAA, rdata_aaaa='dead::1'},
     }, 
     ar={{name={'blarg', 'foo', 'com'}}}, 
    },
   },

   -- 4 check that PTR and SRV work as advertised
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

   -- 5 check that no rewriting happens for arpa stuff (provide
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
                     local ll = dns_db.prefix2ll(p)
                     mst.a(mst.repr_equal(ll, exp_ll),
                           'not equal', ll, exp_ll)
                  end
                        end)
                         end)

local ip6_local = '1.0.0.0.0.0.e.e.b.d.a.e.d.ip6.arpa'

local q_to_r_material = {
   {'bar.com', hp_core.RESULT_FORWARD_EXT},
   {'foo.com', nil},
   {'local', dns_server.RESULT_NXDOMAIN},
   {'foo.local', dns_server.RESULT_NXDOMAIN},
   {'nonexistent.foo.com', dns_server.RESULT_NXDOMAIN},
   {RP .. 'rid1.foo.com', nil},
   {IP .. 'iid1.' .. RP .. 'rid1.foo.com', nil},
   {'x.' .. IP .. 'iid1.' .. RP .. 'rid2.foo.com', hp_core.RESULT_FORWARD_INT},
   {'foo.' .. IP .. 'iid1.' .. RP .. 'rid1.foo.com', hp_core.RESULT_FORWARD_MDNS},
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
   {ip6_local, hp_core.RESULT_FORWARD_MDNS},
   -- remote
   {'1.0.0.0.0.1.e.e.b.d.a.e.d.ip6.arpa', hp_core.RESULT_FORWARD_INT},
}

local n_nonexistent_foo={'nonexistent', 'foo', 'com'}
local n_bar_com={"bar", "com"}
local n_x_mine={'x', IP .. 'iid1', RP .. 'rid1', 'foo', 'com'}
local n_x_reverse=dns_db.name2ll(ip6_local)
local n_y_mine={'y', IP .. 'iid1', RP .. 'rid1', 'foo', 'com'}
local n_x_other={'x', IP.. 'iid1', RP .. 'rid2', 'foo', 'com'}
local n_b_dnssd={'b', '_dns-sd', '_udp', 'foo', 'com'}

local q_bar_com = {name=n_bar_com, qclass=1, qtype=255}
local q_x_mine = {name=n_x_mine, qclass=1, qtype=255}
local q_x_reverse = {name=n_x_reverse, qclass=1, qtype=255}
local q_x_other = {name=n_x_other, qclass=1, qtype=255}
local q_nonexistent = {name=n_nonexistent_foo, qclass=1, qtype=255}
local q_b_dnssd = {name=n_b_dnssd, 
                   qtype=dns_const.TYPE_PTR,
                   qclass=dns_const.CLASS_IN}

local msg_bar_com_nxdomain = {
   h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN},
   qd={q_bar_com},
}

local msg_nonexistent_nxdomain = {
   h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN},
   qd={q_nonexistent},
}

local msg_x_other_content = {
   h={id=123, qr=true, ra=true},
   qd={q_x_other},
   an={
      {name=n_x_other, rtype=dns_const.TYPE_A, rdata_a="7.6.5.4"},
   }
}

local msg_x_mine_nxdomain = {
   h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN},
   qd={q_x_mine},
}

local msg_b_dnssd = {
   h={id=123, qr=true, ra=true},
   qd={q_b_dnssd},
   an={
      {name=n_b_dnssd, 
       rtype=dns_const.TYPE_PTR, rclass=dns_const.CLASS_IN, 
       rdata_ptr={IP .. 'iid1', RP .. 'rid1', 'foo', 'com'}},
      {name=n_b_dnssd, 
       rtype=dns_const.TYPE_PTR, rclass=dns_const.CLASS_IN, 
       rdata_ptr={IP .. 'iid2', RP .. 'rid1', 'foo', 'com'}},
      {name=n_b_dnssd, 
       rtype=dns_const.TYPE_PTR, rclass=dns_const.CLASS_IN, 
       rdata_ptr={IP .. 'iid3', RP .. 'rid1', 'foo', 'com'}},
      {name=n_b_dnssd, 
       rtype=dns_const.TYPE_PTR, rclass=dns_const.CLASS_IN, 
       rdata_ptr={IP .. 'iid1', RP .. 'rid2', 'foo', 'com'}},
   },
}

local rr_x_mine = {name=n_x_mine, rtype=dns_const.TYPE_A, rdata_a="8.7.6.5", rclass=dns_const.CLASS_IN}

local rr_y_mine = {name=n_y_mine, rtype=dns_const.TYPE_A, rdata_a="9.8.7.6", rclass=dns_const.CLASS_IN}

local rr_x_reverse = {name=n_x_reverse, rtype=dns_const.TYPE_PTR, rdata_ptr=n_x_mine, rclass=dns_const.CLASS_IN}

local rr_x_reverse_local = mst.table_copy(rr_x_reverse)
rr_x_reverse_local.rdata_ptr = {'x', 'local'}
rr_x_reverse_local.ttl = 123


local msg_x_mine_result = {
   h={id=123, qr=true, ra=true},
   qd={q_x_mine},
   an={
      rr_x_mine,
   },
   ar={
      rr_y_mine,
   }
}

local msg_x_reverse_result = {
   h={id=123, qr=true, ra=true},
   qd={q_x_reverse},
   an={
      rr_x_reverse,
   },
}

local rr_x_local = mst.table_copy(rr_x_mine)
rr_x_local.name = {'x', 'local'}
rr_x_local.ttl = 234

local rr_y_local = mst.table_copy(rr_y_mine)
rr_y_local.name = {'y', 'local'}
rr_y_local.ttl = 345

local hp_process_dns_results = {
   -- first case - forward ext, fails
   {
      {"8.8.8.8", {h={id=123}, qd={q_bar_com}}},
      nil,
   },
   -- second case - forward ext, succeeds, but op fails (nxdomain)
   {
      {"8.8.8.8", {h={id=123}, qd={q_bar_com}}},
      msg_bar_com_nxdomain,
   },
   -- forward int
   {
      {OTHER_IP, {h={id=123}, qd={q_x_other}}},
      msg_x_other_content,
   },
}

local hp_process_mdns_results = {
   -- error => nil
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, hp_core.MDNS_TIMEOUT},
      nil,
   },
   -- timeout => should result in empty list
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, hp_core.MDNS_TIMEOUT},
      {},
   },
   -- ok
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, hp_core.MDNS_TIMEOUT},
      {
         -- 3 rr's - one matching x.local, additional record y.local,
         -- and third bar.com that should not be propagated

         rr_x_local,
         rr_y_local,
         {name={'bar', 'com'}, rtype=dns_const.TYPE_A, rdata_a="1.2.3.4", rclass=dns_const.CLASS_IN, ttl=123},
      }
   },
   -- ok, with ip
   {
      {"eth0", {name=n_x_reverse, qclass=1, qtype=255}, hp_core.MDNS_TIMEOUT},
      {
         rr_x_reverse_local,
      }
   },
   
}

local hp_process_tests = {
   -- #1 forward ext, fails
   {
      q_bar_com,
      nil,
   },
   -- #2 forward ext, succeeds
   {
      q_bar_com,
      msg_bar_com_nxdomain,
   },
   -- #3 forward int
   {
      q_x_other,
      msg_x_other_content,
   },
   -- #4 nxdomain
   {
      q_nonexistent,
      msg_nonexistent_nxdomain,
   },
   -- #5 mdns forward - error
   {
      q_x_mine,
   },
   -- #6 mdns forward - timeout
   {
      q_x_mine,
      msg_x_mine_nxdomain,
   },
   -- #7 mdns forward - real result
   {
      q_x_mine,
      msg_x_mine_result,
   },
   -- #8 mdns forward - reverse address
   {
      q_x_reverse,
      msg_x_reverse_result,
   },
   -- #9 browse path
   {
      q_b_dnssd,
      msg_b_dnssd,
   }
}



function assert_dns_result_equals(exp, got)
   if exp == got
   then
      return 
   end
   mst.d('considering exp', exp)
   mst.d('considering got', got)

   mst.a(#exp == #got)
   mst.a(exp[1] == got[1])
   -- got is probably within dns_channel.message - remove the wrapper
   mst.a(#got == 2, 'wrong #got', got)
   local gcmsg = got[2]
   mst.a(gcmsg and gcmsg.get_msg, 'missing cmsg', got)
   local gmsg = gcmsg:get_msg()
   mst.a(mst.repr_equal(gmsg, exp[2]), 'not same - exp/got', exp[2][1], gmsg)
end

function clear_msg_ttls(msg)
   for i, f in ipairs{'an', 'ar'}
   do
      for i, rr in ipairs(msg[f] or {})
      do
         rr.ttl = nil
      end
   end
end

function assert_cmsg_result_equals(exp, got)
   if exp == got
   then
      return 
   end
   mst.a(got and got.get_msg, 'no got/get_msg', exp, got)
   clear_msg_ttls(exp)
   clear_msg_ttls(got:get_msg())
   mst.a(mst.repr_equal(exp, got:get_msg()), 'not same - exp/got', exp, got)
end

describe("hybrid_proxy", function ()
            local hp
            local canned_mdns
            local l1, l2, l3
            local mdns, dns
            before_each(function ()
                           local f, g
                           --mst.repr_show_duplicates = true
                           mdns = _t.fake_callback:new{name='mdns',
                                                       --assert_equals=assert_dns_result_equals,
                                                      }
                           dns = _t.fake_callback:new{name='dns',
                                                      assert_equals=assert_dns_result_equals,
                                                     }
                           
                           hp = hp_core.hybrid_proxy:new{rid='rid1',
                                                         domain=DOMAIN_LL,
                                                         mdns_resolve_callback=mdns,
                                                        }
                           l1 = {
                              {iid='iid1',
                               ip='1.2.3.4',
                               ifname='eth0',
                               prefix='dead:bee0::/48',
                              },
                              {iid='iid2',
                               ip='1.2.3.4',
                               ifname='eth1',
                               prefix='dead:beef::/48',
                              },
                              {iid='iid3',
                               ifname='eth2',
                              },
                              {iid='iid1',
                               ip='2.3.4.5',
                               ifname='eth0',
                               prefix='10.11.12.0/24',
                              },

                           }
                           l2 = {
                              'dead::/16',
                              '10.0.0.0/8',
                           }
                           -- XXX - convert these to name+ip pairs
                           l3 = {
                              -- forward zone
                              {name='i-iid1.r-rid2' .. DOMAIN_SUFFIX,
                               ip=OTHER_IP,
                               --prefix='dead:bee1::/48',
                               browse=true,
                              },
                              -- v6 reverse zone'
                              {name='1.e.e.b.d.a.e.d.ip6.arpa',
                               ip=OTHER_IP},
                              -- v4 reverse zone
                              {name='13.11.10.in-addr.arpa',
                               ip=OTHER_IP},
                           }
                           function hp:iterate_lap(f)
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
                           function hp:iterate_remote_zones(f)
                              for i, v in ipairs(l3)
                              do
                                 f(v)
                              end
                           end
                           function hp:forward(req, server)
                              return dns(server, req)
                           end
                        end)
            after_each(function ()
                          hp:done()

                          -- shouldn't have scr running anyway, we use only
                          -- in-system state

                          --mst.a(scr.clear_scr())
                          dns:done()
                          mdns:done()

                       end)
            it("match works (correct decisions on various addrs) #match", function ()
                  _t.test_list(q_to_r_material,
                               function (n)
                                  local q = {name=dns_db.name2ll(n)}
                                  local msg = {qd={q}}
                                  local cmsg = dns_channel.msg:new{msg=msg}
                                  local r, err = hp:match(cmsg)
                                  mst.d('got', r, err)
                                  return r
                               end)
                                                                          end)
            it("iterate_usable_prefixes fallback works #iup", function ()
                  hp.iterate_usable_prefixes = nil
                  local ran
                  hp:iterate_usable_prefixes(function (p)
                                                mst.d('got', p)
                                                ran = true
                                             end)
                  mst.a(ran)

                   end)
            it("dns req->mdns q conversion works #d2m", function ()
                  _t.test_list(dns_q_to_mdns_material,
                               function (q)
                                  local msg = {qd={q}}
                                  local req = dns_channel.msg:new{msg=msg}
                                  local r, err = hp:rewrite_dns_req_to_mdns_q(req, DOMAIN_LL)
                                  return r
                               end
                              )
                                                        end)
            it("mdns->dns conversion works #m2d", function ()
                  local msg = {
                     h={id=123},
                     qd={
                        dns_dummy_q,
                     }
                  }
                  local req = dns_channel.msg:new{msg=msg}
                  local q, err = hp:rewrite_dns_req_to_mdns_q(req, DOMAIN_LL)
                  mst.a(q)
                  _t.test_list(mdns_rrs_to_dns_reply_material,
                               function (rrs)
                                  -- code assumes that the rrs are
                                  -- copied due to e.g. ttls or
                                  -- whatnot
                                  rrs = mst.table_deep_copy(rrs)
                                  -- fill in some fake ttls too
                                  for i, rr in ipairs(rrs)
                                  do
                                     -- perhaps not - easier comparison without
                                     rr.ttl = 123
                                  end
                                  return hp:rewrite_rrs_from_mdns_to_reply_msg(req, q, rrs, DOMAIN_LL)
                               end,
                               assert_cmsg_result_equals)
                                             end)
            it("dns->mdns->reply flow works #flow", function ()
                  -- these are most likely the most complex samples -
                  -- full message interaction 

                  -- twice to account for udp + tcp
                  dns.array:extend(hp_process_dns_results)
                  dns.array:extend(hp_process_dns_results)

                  mdns.array:extend(hp_process_mdns_results)
                  mdns.array:extend(mst.table_deep_copy(hp_process_mdns_results))

                  local is_tcp = false

                  function test_one(oq)
                     local q = {name=dns_db.name2ll(oq.name),
                                qtype=oq.qtype or dns_const.TYPE_ANY,
                                qclass=oq.qclass or dns_const.CLASS_IN}
                     local msg = {qd={q}, h={id=TEST_ID}}
                     local cmsg = dns_channel.msg:new{msg=msg, ip=TEST_SRC, tcp=is_tcp}
                     local r, src = hp:process(cmsg)
                     if r
                     then
                        if r.get_msg
                        then
                           -- sanity check that tcp/ip fields
                           -- propagate correctly
                           mst.a(r.tcp == cmsg.tcp)
                           local ip = r.ip
                           mst.a(ip, 'no ip?!?', r)
                           mst.a(ip == TEST_SRC, 'wrong ip', ip)

                           r = r:get_msg()
                        end
                        mst.a(r.h, 'no header', r)
                        mst.a(r.h.id == msg.h.id)

                        -- get rid of ttls
                        clear_msg_ttls(r)

                        -- convert result to binary, and then back
                        -- (=normalize it)
                        mst.d('normalizing', r)
                        local b = dns_codec.dns_message:encode(r)
                        r = dns_codec.dns_message:decode(b)
                     end
                     return r
                  end

                  function canonize_output(o)
                     mst.a(#o <= 2, 'wrong o', o)
                     local input, output = unpack(o)
                     if output
                     then
                        mst.d('converting', output)
                        local b = dns_codec.dns_message:encode(output)
                        output = dns_codec.dns_message:decode(b)
                     end
                     return {input, output}
                  end

                  local ol = mst.array_map(hp_process_tests,
                                           canonize_output)

                  -- first via UDP
                  mst.d('running udp tests')
                  l = mst.table_deep_copy(ol)
                  _t.test_list(l, test_one)
                  -- then via TCP
                  mst.d('running tcp tests')
                  is_tcp = true
                  l = mst.table_deep_copy(ol)
                  _t.test_list(l, test_one)

                                                    end)
                         end)
