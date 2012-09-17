-- -*-lua-*-
--
-- $Id: trickle.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Created:       Mon Sep 17 13:12:19 2012 mstenber
-- Last modified: Mon Sep 17 14:26:44 2012 mstenber
-- Edit time:     14 min
--

-- Trickle implementation - just done as a test of getting Lua code working

-- Assumed parameters during new (at least): imin, imax, k, env

-- env should have:
--  send() method for env to send it's state
--  time() 

-- env should call
--  run() periodically (at least as often as next() wants)
--  got_consistent() when receiving something consistent
--  got_inconsistent() when receiving something inconsistent

module("trickle", package.seeall)

Trickle = { }

function Trickle:new(o)
   o = o or {} 
   setmetatable(o, self)
   self.__index = self
   o:start()
   return o
end

-- alg:1
function Trickle:start()
   -- check parameters were really provided
   assert(self.imin, "imin missing")
   assert(self.imax, "imax missing")
   assert(self.k, "k missing")
   assert(self.env, "env missing")


   self.i = self.imin
   self.c = 0
   -- alg:2
   self:_reset_timer()
end

function Trickle:_reset_timer()
   self.t = self.i * (1 + math.random()) / 2
   self.st = self.env:time()
   self.sent = false
end

function Trickle:run()
   local nt = self.env:time() - self.st
   -- alg:4
   if nt >= self.t and not self.sent
   then
      self.sent = true
      self.env:send()
    end
   -- alg:5
   if nt >= self.i
   then
      self.i = self.i * 2
      if self.i >= self.imax
      then
         self.i = self.imax
      end
      self:_reset_timer()
   end
end

function Trickle:next()
   local nt = self.env:time() - self.st
   local td = nt - self.t
   return td
end

-- alg:3
function Trickle:got_consistent()
   self.c = self.c + 1
end

-- alg:6
function Trickle:got_inconsistent()
   if self.i > self.imin
   then
      self.i = self.imin
      self:_reset_timer()
   end
end

