#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Tue Sep 18 12:25:32 2012 mstenber
-- Last modified: Tue Sep 18 12:26:20 2012 mstenber
-- Edit time:     1 min
--

require "luacov"
require "busted"

local skv = require 'skv'

describe("class init", 
         function()
            it("can be created", 
               function()
                  local o = skv:new()
               end)
         end)
