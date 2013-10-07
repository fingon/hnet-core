#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dshell.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct 29 16:06:24 2012 mstenber
-- Last modified: Mon Oct  7 14:09:37 2013 mstenber
-- Edit time:     10 min
--

-- dummy shell implementation, which has strict assumptions about
-- inputs and outputs

require 'mst'
require 'mst_test'

module(..., package.seeall)

local _parent = mst_test.fake_callback

dshell = _parent:new_subclass{class='dshell'}

function dshell:set_array(a)
   -- the inputs/outputs for dshell are traditionally just input +
   -- output strings however, we have to convert them to lists of
   -- length 1 to match fake_callback
   _parent.set_array(self, mst.array_map(a, function (o)
                                            local cmd, r = unpack(o)
                                            return {{cmd}, r}
                                            end))
end

function dshell:get_shell()
   local function fakeshell(s)
      mst.d('fakeshell#', s)
      return self.__call(self, s)
   end
   return fakeshell
end
