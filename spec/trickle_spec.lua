#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: busted_trickle.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Created:       Mon Sep 17 13:13:02 2012 mstenber
-- Last modified: Tue Oct  2 13:50:26 2012 mstenber
-- Edit time:     34 min
--

-- Make sure that the trickle module is sane

require 'strict'
require "busted"
require "trickle"

function new_dummy_client()
   local DummyClient = { t = 0 }
   function DummyClient:send()
   end

   function DummyClient:time()
      return self.t
   end
   return DummyClient
end

-- global variables used here

dc = nil
t = nil

describe("trickle startup", 
         function()
            it("asserts if no parameters", 
               function()
                  -- no arguments -> invalid (imin, imax, k, env mandatory)
                  assert.error(function()
                                  local t = trickle.Trickle:new()
                               end)
               end)
            it("starts if parameters", 
               function()
                  local tdc = new_dummy_client()
                  local tt = trickle.Trickle:new{imin=1, imax=123, env=tdc, k=2}
               end)
         end)

describe("trickle",
         function()
            setup(function()
                     dc = mock(new_dummy_client())
                     t = trickle.Trickle:new{imin=1, imax=123, env=dc, k=2}
                  end)
            it("calls send after ticking",
               function()
                  assert.spy(dc.send).was_not.called()
                  dc.t = 1
                  t:run()
                  assert.spy(dc.send).was.called()
               end)
            it("never exceeds imax",
               function()
                  for i=1,5000
                  do
                     dc.t = i
                     t:run()
                  end
                  assert.are.same(t.i, t.imax)
               end)
         end)
