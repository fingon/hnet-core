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
-- Last modified: Tue Nov 27 15:21:16 2012 mstenber
-- Edit time:     1 min
--

require 'pm_core'
collectgarbage()
print(math.floor(collectgarbage('count')), 'pm_core')
