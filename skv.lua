#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Tue Sep 18 12:23:19 2012 mstenber
-- Last modified: Tue Sep 18 12:30:30 2012 mstenber
-- Edit time:     3 min
--

local skv = {}
skv.__index = skv

local sm = require 'skv_sm'

function skv:new()
   local o = {}
   o.fsm = sm:new({owner=o})
   setmetatable(o, self)
   o.fsm:enterStartState()
   return o
end

function skv:init()
   self.fsm:Initialized()
end

function skv:connect()
   self.fsm:Connected()
end

function skv:send_local_updates()
end

function skv:send_listeners()
end

return skv
