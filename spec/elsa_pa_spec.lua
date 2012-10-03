#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: elsa_pa_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Wed Oct  3 11:49:00 2012 mstenber
-- Last modified: Wed Oct  3 17:18:39 2012 mstenber
-- Edit time:     18 min
--

require 'mst'
require 'busted'
require 'elsa_pa'
require 'skv'
require 'ssloop'

delsa = mst.create_class{class='delsa'}

describe("elsa_pa", function ()
            it("can be created", function ()
                  local e = delsa:new()
                  local skv = skv.skv:new{long_lived=false, port=31337}
                  local ep = elsa_pa.elsa_pa:new{elsa=e, skv=skv}
                  ep:run()
                  ep:done()
                  skv:done()
                  e:done()
                  local r = ssloop.loop():clear()
                  mst.a(not r, 'event loop not clear')

                                 end)
                    end)
