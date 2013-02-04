#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dint.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Feb  4 16:22:51 2013 mstenber
-- Last modified: Mon Feb  4 16:24:10 2013 mstenber
-- Edit time:     1 min
--

local mst = require 'mst'

module(...)

-- minimalist dummy int class (which honors the Lua comparison
-- operators)

dint = mst.create_class{class='dint'}

function dint:repr_data()
   return 'v=' .. self.v
end

function dint:__lt(o)
   return self.v < o.v
end

