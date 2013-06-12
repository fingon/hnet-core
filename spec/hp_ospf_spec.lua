#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: hp_ospf_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May 23 17:40:20 2013 mstenber
-- Last modified: Wed Jun 12 16:27:03 2013 mstenber
-- Edit time:     66 min
--

require 'busted'
require 'hp_ospf'
require 'scr'
require 'dns_channel'
require 'skv'
require 'elsa_pa'

local _t = require 'mst_test'

module('hp_ospf_spec', package.seeall)

local DOMAIN_LL={'foo', 'com'}

-- we assume that hp_core works; what we need to verify is that having
-- skv set up correctly results in appropriate returns for the APIs
-- hp_core uses.

local USP = 'dead::/16'
local ASP1 = 'dead:beef::/64'
local RID1 = 'rid1'
local IID1 = 'iid1'
local IP1 = '1.2.3.4'
local IP1_MASK = IP1 .. '/32'

local ASP2 = 'dead:bee0::/64'
local RID2 = 123
local RNAME2 = 'rid2'
local IID2 = 23
local IP2 = '2.3.4.5'

local NAME3 = 'bar.com'
local IP3 = '3.4.5.6'

local IFNAME = 'if-name'

describe("hybrid_ospf", function ()
            after_each(function ()
                          local r = ssloop.loop():clear()
                          mst.a(not r, 'event loop not clear', r)

                       end)
            it("works", function ()
                  local hp, s

                  hp = hp_ospf.hybrid_ospf:new{domain=DOMAIN_LL,
                                               mdns_resolve_callback=true,
                                              }
                  s = skv.skv:new{long_lived=true,port=0}
                  hp:attach_skv(s)
                  
                  -- XXX - test that this stuff works
                  local f, l = _t.create_storing_iterator_and_list()

                  -- initially iteration should do nothing, as no state
                  hp:iterate_usable_prefixes(f)
                  hp:iterate_lap(f)
                  mst.a(#l == 0)

                  -- wish we had real test material. oh well, this
                  -- should be enough.
                  s:set(elsa_pa.OSPF_RID_KEY, 'rid1')
                  s:set(elsa_pa.OSPF_USP_KEY, 
                        {
                           {
                              prefix=USP,
                           }
                        })

                  local n = {RNAME2}
                  mst.array_extend(n, DOMAIN_LL)
                  mst.d('added fake remote zone', n)
                  s:set(elsa_pa.OSPF_HP_ZONES_KEY,
                        {
                           -- inetrnally learnt one -> should be in browse path
                           {name=n,
                            ip=IP2,
                            browse=1,
                           },
                           -- one externally learnt one
                           {name=NAME3,
                            ip=IP3,
                            search=1,
                           },
                        }
                       )

                  local lap1 = {
                     iid=IID1,
                     ifname=IFNAME,
                     prefix=ASP1,
                     address=IP1_MASK,
                  }

                  s:set(elsa_pa.OSPF_LAP_KEY, 
                        {lap1
                        })
                  
                  hp:iterate_usable_prefixes(f)
                  hp:iterate_lap(f)
                  local e = {
                     -- usable prefix
                     {USP},

                     -- lap
                     {lap1},
                  }
                  
                  mst.a(mst.repr_equal(l, e), 'not same', l, e)

                  -- make sure this works too
                  local root = hp:get_root()

                  -- make sure ll's are sane
                  mst.a(root.iterate_subtree, 'missing iterate_subtree', root)
                  root:iterate_subtree(function (n)
                                          n:get_ll()
                                       end)

                  -- test that by default we get Google address
                  local srv = hp:get_server()
                  mst.a(srv == dns_const.GOOGLE_IPV4)

                  local V6 = 'dead:beef::1'
                  local V4 = '1.2.3.4'
                  s:set(elsa_pa.OSPF_IPV4_DNS_KEY, {V4})
                  s:set(elsa_pa.OSPF_DNS_KEY, {V6})

                  local srv = hp:get_server()
                  mst.a(srv == V6)

                  s:set(elsa_pa.OSPF_DNS_KEY, false)

                  local srv = hp:get_server()
                  mst.a(srv == V4)

                  s:set(elsa_pa.OSPF_IPV4_DNS_KEY, false)

                  local srv = hp:get_server()
                  mst.a(srv == dns_const.GOOGLE_IPV4)

                  -- make sure we get appropriate verdict for _named_
                  -- rid2
                  local n = {'foo', RNAME2}
                  mst.array_extend(n, DOMAIN_LL)
                  local q = {name=n}
                  local msg = {qd={q}}
                  local cmsg = dns_channel.msg:new{msg=msg}
                  mst.d('matching', cmsg)
                  local r, err = hp:match(cmsg)
                  mst.a(r == hp_core.RESULT_FORWARD_INT, 'got', r, err)

                  if false
                  then
                     -- <own-name>.<domain> should give IPs.
                     -- or maybe not? hmmh. Have to think about this.

                     local n = {hp:rid2label(RID1)}
                     mst.array_extend(n, DOMAIN_LL)
                     local q = {name=n, 
                                qclass=dns_const.CLASS_IN, qtype=dns_const.TYPE_A}
                     local msg = {qd={q}}
                     local cmsg = dns_channel.msg:new{msg=msg}
                     local r, err = hp:match(cmsg)
                     mst.a(type(r) == 'table', 'non-table', r, err)
                     mst.a(#r > 0)

                  end

                  -- make sure skv has magically these two new
                  -- hp-originated keys:

                  local v = s:get(elsa_pa.HP_MDNS_ZONES_KEY)
                  local e = {
                     {browse=1, ip="1.2.3.4", name=IFNAME .. ".r-rid1.foo.com"}, 
                     {ip="1.2.3.4", 
                      name="0.0.0.0.0.0.0.0.f.e.e.b.d.a.e.d.ip6.arpa"},
                  }
                  mst.a(mst.repr_equal(v, e), 'not same', v, e)

                  local v = s:get(elsa_pa.HP_SEARCH_LIST_KEY)
                  local e = {'foo.com', NAME3}
                  mst.a(mst.repr_equal(v, e), 'not same', v, e)

                  local b_dns_sd_ll = mst.table_copy(dns_const.B_DNS_SD_LL)
                  mst.array_extend(b_dns_sd_ll, DOMAIN_LL)
                  local q = {name=b_dns_sd_ll}
                  local msg = {qd={q}}
                  local r, err = hp:match(cmsg)
                  mst.a(r == hp_core.RESULT_FORWARD_INT, 'got', r, err)

                  hp:done()
                  s:done()
                        end)
                        end)
