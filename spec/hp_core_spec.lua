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
-- Last modified: Tue May 14 16:01:23 2013 mstenber
-- Edit time:     195 min
--

require 'busted'
require 'hp_core'
require 'scr'

module('hp_core_spec', package.seeall)

local DOMAIN_LL={'foo', 'com'}
local TEST_SRC='4.3.2.1'
local TEST_ID=123
local OTHER_IP='3.4.5.6'

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
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN}, 
     qd={dns_dummy_q},
     an={}, ar={}, 
    },
   },
   
   -- nothing _matching_ found => name error
   {{
       -- one fake-RR, but with wrong name
       {name={'blarg', 'local'}},
    },
    {h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN}, 
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
   {'x.iid1.rid2.foo.com', hp_core.RESULT_FORWARD_INT},
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

local n_nonexistent_foo={'nonexistent', 'foo', 'com'}
local n_bar_com={"bar", "com"}
local n_x_mine={'x', 'iid1', 'rid1', 'foo', 'com'}
local n_y_mine={'y', 'iid1', 'rid1', 'foo', 'com'}
local n_x_other={'x', 'iid1', 'rid2', 'foo', 'com'}

local q_bar_com = {name=n_bar_com, qclass=1, qtype=255}
local q_x_mine = {name=n_x_mine, qclass=1, qtype=255}
local q_x_other = {name=n_x_other, qclass=1, qtype=255}
local q_nonexistent = {name=n_nonexistent_foo, qclass=1, qtype=255}

local msg_bar_com_nxdomain = {
   h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN},
   qd={q_bar_com},
}

local msg_nonexistent_nxdomain = {
   h={id=123, qr=true, ra=true, rcode=dns_const.RCODE_NXDOMAIN},
   qd={q_nonexistent},
   ar={}, an={}-- impl. artifacts
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
   ar={}, an={}-- impl. artifacts
}

local rr_x_mine = {name=n_x_mine, rtype=dns_const.TYPE_A, rdata_a="8.7.6.5", rclass=dns_const.CLASS_IN}

local rr_y_mine = {name=n_y_mine, rtype=dns_const.TYPE_A, rdata_a="9.8.7.6", rclass=dns_const.CLASS_IN}

local msg_x_mine_result = {
   h={id=123, qr=true, ra=true},
   qd={mst.table_deep_copy(q_x_mine)},
   an={
      rr_x_mine,
   },
   ar={
      rr_y_mine,
   }
}

local rr_x_local = mst.table_copy(rr_x_mine)
rr_x_local.name = {'x', 'local'}

local rr_y_local = mst.table_copy(rr_y_mine)
rr_y_local.name = {'y', 'local'}

local hp_process_dns_results = {
   -- first case - forward ext, fails
   {
      {"8.8.8.8", {{h={id=123}, qd={q_bar_com}}, "4.3.2.1", false}},
      nil,
   },
   -- second case - forward ext, succeeds, but op fails (nxdomain)
   {
      {"8.8.8.8", {{h={id=123}, qd={q_bar_com}}, "4.3.2.1", false}},
      msg_bar_com_nxdomain,
   },
   -- forward int
   {
      {OTHER_IP, {{h={id=123}, qd={q_x_other}}, "4.3.2.1", false}},
      msg_x_other_content,
   },
}

local hp_process_tests = {
   -- first case - forward ext, fails
   {
      q_bar_com,
      nil,
   },
   -- second case - forward ext, succeeds
   {
      q_bar_com,
      msg_bar_com_nxdomain,
   },
   -- third case, forward int
   {
      q_x_other,
      msg_x_other_content,
   },
   -- nxdomain
   {
      q_nonexistent,
      msg_nonexistent_nxdomain,
   },
   -- mdns forward - error
   {
      q_x_mine,
   },
   -- mdns forward - timeout
   {
      q_x_mine,
      msg_x_mine_nxdomain,
   },
   -- mdns forward - real result
   {
      q_x_mine,
      msg_x_mine_result,
   },
}

local hp_process_mdns_results = {
   -- error => nil
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, 0.5},
      nil,
   },
   -- timeout => should result in empty list
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, 0.5},
      {},
   },
   -- ok
   {
      {"eth0", {name={"x", "local"}, qclass=1, qtype=255}, 0.5},
      {
         -- 3 rr's - one matching x.local, additional record y.local,
         -- and third bar.com that should not be propagated

         rr_x_local,
         rr_y_local,
         {name={'bar', 'com'}, rtype=dns_const.TYPE_A, rdata_a="1.2.3.4", rclass=dns_const.TYPE_IN},
      }
   },
}


fake_callback = mst.create_class{class='fake_callback'}

function fake_callback:init()
   self.array = self.array or mst.array:new{}
   self.i = self.i or 0
end

function fake_callback:repr_data()
   return mst.repr{i=self.i,n=#self.array,name=self.name}
end

function fake_callback:__call(...)
   self:a(self.i < #self.array, 'not enough left to serve', {...})
   self.i = self.i + 1
   local got = {...}
   local exp, r = unpack(self.array[self.i])
   self:a(mst.repr_equal(got, exp), 
          'non-expected input - exp/got', exp, got)
   return r
end

function fake_callback:uninit()
   self:a(self.i == #self.array, 'wrong amount consumed', self.i, #self.array, self.array)
end

function test_list(a, f)
   for i, v in ipairs(a)
   do
      local input, output = unpack(v)

      -- then call test function
      local result, err = f(input)

      -- and make sure that (repr-wise) result is correct
      mst.a(mst.repr_equal(result, output), 
            'not same exp/got', 
            output, result, err,
           'for',
           input)
   end
end

describe("hybrid_proxy", function ()
            local hp
            local canned_mdns
            local l1, l2
            local mdns, dns
            before_each(function ()
                           local f, g
                           mdns = fake_callback:new{name='mdns'}
                           dns = fake_callback:new{name='dns'}
                           
                           hp = hp_core.hybrid_proxy:new{rid='rid1',
                                                         domain=DOMAIN_LL,
                                                         mdns_resolve_callback=mdns,
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
                                  ip=OTHER_IP,
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
                              local msg, src, tcp = unpack(req)
                              return dns(server, req), src
                           end
                        end)
            after_each(function ()
                          hp:done()
                          hp = nil

                          -- shouldn't have scr running anyway, we use only
                          -- in-system state

                          --mst.a(scr.clear_scr())
                          dns:done()
                          mdns:done()

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
            it("dns->mdns->reply flow works #flow", function ()
                  -- these are most likely the most complex samples -
                  -- full message interaction 

                  -- twice to account for udp + tcp
                  dns.array:extend(hp_process_dns_results)
                  function rewrite_dns_to_tcp(l)
                     return mst.array_map(l, function (o)
                                             mst.a(#o <= 2, 'wrong # in o', #o, o)
                                             local input, resp = unpack(o)
                                             mst.a(#input == 2, 'wrong # in input', #input, input)
                                             -- server + req
                                             local server, req = unpack(input)
                                             mst.a(#req == 3,
                                                  'wrong # in req', #req, req)
                                             local nreq = {req[1], req[2], 
                                                           true}
                                             return {{server, nreq}, resp}
                                             end)
                  end
                  dns.array:extend(rewrite_dns_to_tcp(hp_process_dns_results))

                  mdns.array:extend(hp_process_mdns_results)
                  mdns.array:extend(hp_process_mdns_results)

                  local is_tcp = false

                  function test_one(oq)
                     local q = {name=dns_db.name2ll(oq.name),
                                qtype=oq.qtype or dns_const.TYPE_ANY,
                                qclass=oq.qclass or dns_const.CLASS_IN}
                     local msg = {qd={q}, h={id=TEST_ID}}
                     local r, src = hp:process(msg, TEST_SRC, is_tcp)
                     if r
                     then
                        mst.a(src, 'no src?!?', r)
                        mst.a(src == TEST_SRC, 'wrong src', src)
                        mst.a(r.h.id == msg.h.id)
                     end
                     return r
                  end

                  -- first via UDP
                  test_list(hp_process_tests, test_one)
                  -- then via TCP
                  is_tcp = true
                  test_list(hp_process_tests, test_one)

                   end)
                         end)
