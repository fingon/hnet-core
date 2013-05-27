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
-- Last modified: Mon May 27 14:37:13 2013 mstenber
-- Edit time:     29 min
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
local ASP2 = 'dead:bee0::/64'
local RID1 = 'rid1'
local RID2 = 123
local IID1 = 'iid1'
local IID2 = 234
local IFNAME = 'if-name'
local IP2 = '2.3.4.5/32'

describe("hybrid_ospf", function ()
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
                  hp:iterate_ap(f)
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
                  s:set(elsa_pa.OSPF_ASP_KEY, 
                        {
                           {
                              prefix=ASP1,
                              rid=RID1,
                              iid=IID1,
                           },
                           {
                              prefix=ASP2,
                              rid=RID2,
                              iid=IID2,
                           },
                        })

                  s:set(elsa_pa.OSPF_ASA_KEY, 
                        {
                           {
                              rid=RID1,
                              prefix='1.2.3.4/32',
                           },
                           {
                              rid=RID2,
                              prefix=IP2,
                           },
                        })
                  
                  s:set(elsa_pa.OSPF_LAP_KEY, 
                        {
                           {
                              iid=IID1,
                              ifname=IFNAME,
                              prefix=ASP1,
                           },
                        })
                  
                  hp:iterate_usable_prefixes(f)
                  hp:iterate_ap(f)
                  local e = {
                     -- usable prefix
                     {USP},

                     -- ap
                     {{prefix=ASP1, 
                      iid=IID1, 
                      rid=RID1,
                      ifname=IFNAME,
                      },
                     },
                     {{prefix=ASP2, 
                      iid=IID2, 
                      rid=RID2,
                      ip=IP2,
                      },
                     }
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

                  hp:done()
                  s:done()
                   end)
             end)
