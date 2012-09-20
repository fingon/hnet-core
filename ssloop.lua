#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ssloop.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Thu Sep 20 11:24:12 2012 mstenber
-- Last modified: Thu Sep 20 12:25:48 2012 mstenber
-- Edit time:     41 min
--

-- Minimalist event loop, with ~compatible API to that of the lua_ev,
-- but one with actually debugging on Lua side that works.. hopefully
-- :)

-- Should be also more transparent to the end user due to possibility
-- of debugging it within lua using the usual mst module features.

require 'mst'

module(..., package.seeall)

-- mstwrapper - basic wrapper with started state, and abstract raw_start/stop
local mstwrapper = mst.create_class{started=false, class=mstwrapper}

function mstwrapper:start()
   if not self.started
   then
      self.raw_start()
      self.started = true
   end
   return self
end

function mstwrapper:stop()
   if self.started
   then
      self.raw_stop()
      self.started = false
   end
   return self
end

function mstwrapper:done()
   -- stop us in case caller didn't
   self:stop()
end

--- mstio - wrapper for a single reader or writer

-- reader = if we're reader
-- s = socket
-- callback = who to call
local mstio = mstwrapper:new_subclass{mandatory={'reader', 's', 'callback'}, 
                                      class='mstio'}
function mstio:init()
   self.started = false
end

function mstio:raw_start()
   local l = _loop
   local a = self.reader and l.r or l.w
   local h = self.reader and l.rh or l.wh
   local i = mst.array_find(a, self.s)

   self:a(not i, "we should be missing from event loop socket list")
   table.insert(a, self.s)
   h[self] = true
end

function mstio:raw_stop()
   local l = _loop
   local a = self.reader and l.r or l.w
   local h = self.reader and l.rh or l.wh
   local i = mst.array_find(a, self.s)

   self:a(i, "we're missing from event loop socket list")
   self:a(h[self] ~= nil, "we're missing from event loop hash")
   h[self] = nil
   table.remove(a, i)
end

--- msttimeout - wrapper for timeout 

local msttimeout = mstwrapper:new_subclass{mandatory={'timeout', 'callback'},
                                           class='msttimeout'}

function msttimeout:init()
   local l = _loop
   self.started = false
   table.insert(l.t, self)
end

function msttimeout:done()
   local l = _loop
   local i = mst.array_find(l.t, self)

   self:a(i, "we're missing from event loop timeout list")
   table.remove(l.t, i)
end

function msttimeout:raw_start()
   -- nop - event loop calculates who's active
end

function msttimeout:raw_stop()
   -- nop - event loop calculates who's active
end

--- ssloop - main eventloop

local ssloop = mst.create_class{class='ssloop'}

local _loop = false

function ssloop:init()
   -- arrays to be passed to select
   self.r = {}
   self.w = {}
   
   -- hashes of mstio instances
   self.rh = {}
   self.wh = {}

   -- array of timeouts
   self.t = {}
end

function ssloop:new_reader(s, callback)
   local o = mstio:new{s=s, callback=callback, reader=true}
   -- as side effect of init, added to r/rh
end

function ssloop:new_writer(s, callback)
   local o = mstio:new{s=s, callback=callback, reader=false}
   -- as side effect of init, added to w/wh
end

function ssloop:new_timeout_delta(secs, callback)
   local o = msttimeout:new{t=os.time()+secs,
                            callback=callback}
end

function ssloop:poll(timeout)
   -- run select _once_, and run resulting callbacks

   -- first off, see if timeouts expired, if so, poll was 'success'
   -- without select
   local time = os.time()
   if self:run_timeouts(time) > 0
   then
      return
   end

   local d = self:next_timeout(now)
   if timeout and (not d or d > timeout)
   then
      d = timeout
   end
   r, w, err = socket.select(self.r, self.w, d)

   for o in r
   do
      o:callback()
   end
   for o in w
   do
      o:callback()
   end

   -- finally run the timeouts so they have maximal time available.. ;-)
   local time = os.time()
   self:run_timeouts(time)
end

function ssloop:run_timeouts(now)
   local c = 0
   for i, v in ipairs(self.t)
   do
      if v.started and v.timeout <= now
      then
         v.callback()
         v:done()
         c = c + 1
      end
   end
   return c
end

function ssloop:next_timeout(now)
   local c = 0
   local best = nil
   for i, v in ipairs(self.t)
   do
      -- ignore if it's not started
      if v.started
      then
         -- there shouldn't be any with v.timeout <= now 
         assert(v.timeout > now)
         local d = v.timeout - now
         if not best or best > d
         then
            best = d
         end
      end
   end
   return best
end

--- public API

function loop()
   -- get the singleton loop
   if not _loop
   then
      _loop = ssloop:new()
   end
   return _loop
end

