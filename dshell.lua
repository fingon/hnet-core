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
-- Last modified: Mon Oct 29 16:14:20 2012 mstenber
-- Edit time:     2 min
--

-- dummy shell implementation, which has strict assumptions about
-- inputs and outputs

require 'mst'

module(..., package.seeall)

dshell = mst.create_class{class='dshell'}

function dshell:init()
   self:set_array({})
end

function dshell:set_array(a)
   self.arr = a
   self.arri = 0
end

function dshell:get_shell()
   function fakeshell(s)
      mst.d('fakeshell#', s)
      self.arri = self.arri + 1
      mst.a(self.arri <= #self.arr, 'tried to consume with array empty', s)
      local t, v = unpack(self.arr[self.arri])
      mst.a(t == s, 'mismatch - expected', t, 'got', s)
      return v
   end
   return fakeshell
end


function dshell:check_used()
   mst.a(self.arri == #self.arr, 'did not consume all?', self.arri, #self.arr)
end
