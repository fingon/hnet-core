#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: temp.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Nov 27 15:18:07 2012 mstenber
-- Last modified: Mon Dec  3 15:51:10 2012 mstenber
-- Edit time:     3 min
--

local tested_module = 'pm_core'
require(tested_module)
--require 'mst'
collectgarbage('collect')
print(math.floor(collectgarbage('count')), tested_module)
