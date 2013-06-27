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
-- Last modified: Thu Jun 27 10:55:41 2013 mstenber
-- Edit time:     3 min
--

-- dummy shell implementation, which has strict assumptions about
-- inputs and outputs

require 'mst'

module(..., package.seeall)

dshell = mst.create_class{class='dshell'}

function dshell:init()
   self:set_array{}
end

function dshell:set_array(a)
   self.arr = a
   self.arri = 0
end

function dshell:get_shell()
   local function fakeshell(s)
      mst.d('fakeshell#', s)
      self.arri = self.arri + 1
      self:a(self.arri <= #self.arr, 'tried to consume with array empty', s)
      local t, v = unpack(self.arr[self.arri])
      mst.a(t == s, 'mismatch line ', self.arri, 'expected', t, 'got', s)
      return v
   end
   return fakeshell
end


function dshell:check_used()
   mst.a(self.arri == #self.arr, 'did not consume all?', self.arri, #self.arr)
end
