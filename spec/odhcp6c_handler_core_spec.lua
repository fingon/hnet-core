#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: odhcp6c_handler_core_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Mar 25 18:27:04 2013 mstenber
-- Last modified: Tue Mar 26 15:26:46 2013 mstenber
-- Edit time:     19 min
--

require "busted"
require "odhcp6c_handler_core"

describe("odhcp6c_handler_core", function ()
            local h
            local env
            local args
            local o
            local t
            local ifname = 'eth0'
            local ok = elsa_pa.PD_SKVPREFIX .. ifname
            before_each(function ()
                           -- default arguments
                           args = {'eth0', 'started'}
                           -- default env (~empty)
                           env = {}
                           -- time
                           t = 1234
                           -- output is by default empty dict
                           o = {}
                           -- and then the handler itself
                           h = odhcp6c_handler_core.ohc:new{
                              getenv = function (k)
                                 return env[k]
                              end,
                              args = args,
                              skv = {
                                 set = function (self, k, v)
                                    mst.d('skv-set', k, v)
                                    o[k] = v
                                 end
                              },
                              time = function ()
                                 return t
                              end
                                                           }
                        end)
            it("works (minimal)", function ()
                  h:run()
                  local v = o[ok]
                  -- make sure we have a value, but it should be empty
                  -- (nothing configured)
                  mst.a(v and #v == 0)
                   end)
            it("rdnss without prefixes", function ()
                  env[odhcp6c_handler_core.ENV_RDNSS] = '1.2.3.4 dead:beef::1'
                  h:run()
                  local v = o[ok]
                  -- should have nothing - no prefixes
                  mst.a(not v or #v == 0)
                   end)
            it("domain without prefixes", function ()
                  env[odhcp6c_handler_core.ENV_DOMAINS] = 'foo.com bar.com'
                  h:run()
                  local v = o[ok]
                  -- should have nothing - no prefixes
                  mst.a(not v or #v == 0)
                   end)
            it("rdnss", function ()
                  env[odhcp6c_handler_core.ENV_PREFIXES] = '2001::/16,1,1,0 dead::/16,1,1 beef::/32,2,3,42'
                  env[odhcp6c_handler_core.ENV_RDNSS] = '1.2.3.4 dead:beef::1'
                  h:run()
                  local v = o[ok]
                  -- should have one entry each (+prefixes)
                  mst.a(v and #v == 2+3)
                   end)
            it("domain", function ()
                  env[odhcp6c_handler_core.ENV_PREFIXES] = '2001::/16,1,1,0 dead::/16,1,1 beef::/32,2,3,42'
                  env[odhcp6c_handler_core.ENV_DOMAINS] = 'foo.com bar.com'
                  h:run()
                  local v = o[ok]
                  -- should have one entry each
                  mst.a(v and #v == 2+3)
                   end)
            it("prefixes", function ()
                  env[odhcp6c_handler_core.ENV_PREFIXES] = '2001::/16,1,1,0 dead::/16,1,1 beef::/32,2,3,42'
                  h:run()
                  local v = o[ok]
                  -- should have one entry each
                  mst.a(v and #v == 3)

                  -- make sure there's only one with pclass
                  mst.a(#v:filter(function (x) return x.pclass end) == 1)
                  v:foreach(function (x)
                               mst.a(x[elsa_pa.PREFIX_KEY])
                               local v = x[elsa_pa.VALID_KEY]
                               local p = x[elsa_pa.PREFERRED_KEY]
                               mst.a(v >= t)
                               mst.a(p >= t)
                               mst.a(p <= v)
                            end)
                  

                   end)
             end)

