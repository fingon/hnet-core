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
-- Last modified: Mon Sep 24 14:44:24 2012 mstenber
-- Edit time:     78 min
--

-- Minimalist event loop, with ~compatible API to that of the lua_ev,
-- but one with actually debugging on Lua side that works.. hopefully
-- :)

-- Should be also more transparent to the end user due to possibility
-- of debugging it within lua using the usual mst module features.

-- API-wise, the input sources all call the given callback at some point.
-- this behavior can be start()ed, stop()ed, and when the object is
-- no longer useful it can be killed with done()

require 'mst'
require 'socket'

module(..., package.seeall)

-- mstwrapper - basic wrapper with started state, and abstract raw_start/stop
local mstwrapper = mst.create_class{started=false, class=mstwrapper}

function mstwrapper:start()
   if not self.started
   then
      self.started = true
      self:raw_start()
   end
   return self
end

function mstwrapper:stop()
   if self.started
   then
      self.started = false
      self:raw_stop()
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
function mstio:raw_start()
   local l = loop()
   local a = self.reader and l.r or l.w
   local h = self.reader and l.rh or l.wh
   local i = mst.array_find(a, self.s)

   self:a(not i, "we should be missing from event loop socket list")
   table.insert(a, self.s)
   h[self.s] = self
end

function mstio:raw_stop()
   local l = loop()
   local a = self.reader and l.r or l.w
   local h = self.reader and l.rh or l.wh
   local i = mst.array_find(a, self.s)

   self:a(i, "we're missing from event loop socket list")
   self:a(h[self.s] ~= nil, "we're missing from event loop hash")
   h[self.s] = nil
   table.remove(a, i)
end

function mstio:repr_data()
   if self.reader
   then
      return 'reader fd:'..tostring(self.s:getfd())
   end
   return 'writer fd:'..tostring(self.s:getfd())
end

--- msttimeout - wrapper for timeout 

local msttimeout = mstwrapper:new_subclass{mandatory={'timeout', 'callback'},
                                           class='msttimeout'}

function msttimeout:init()
   local l = loop()
   self.started = false
   table.insert(l.t, self)
end

function msttimeout:done()
   local l = loop()
   local i = mst.array_find(l.t, self)

   if i
   then
      self:a(i, "we're missing from event loop timeout list")
      table.remove(l.t, i)
   end
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
   -- not added anywhere before start()
   self:d('added new reader', o)
   return o
end

function ssloop:new_writer(s, callback)
   local o = mstio:new{s=s, callback=callback, reader=false}
   -- not added anywhere before start()
   self:d('added new writer', o)
   return o
end

local function time()
   -- where can we get good time info? socket!
   -- (the normal os.time() returns only time in seconds)
   return socket.gettime()
end

function ssloop:new_timeout_delta(secs, callback)
   local o = msttimeout:new{timeout=time()+secs,
                            callback=callback}
   -- as a side effect, added to t
   self:d('added new timeout', o)
   return o
end

function ssloop:poll(timeout)
   self:d('poll')

   -- run select _once_, and run resulting callbacks

   -- first off, see if timeouts expired, if so, poll was 'success'
   -- without select
   local now = time()
   if self:run_timeouts(now) > 0
   then
      return
   end

   local d = self:next_timeout(now)
   if timeout and (not d or d > timeout)
   then
      d = timeout
   end

   self:d('select()', #self.r, #self.w, d)
   r, w, err = socket.select(self.r, self.w, d)

   for _, s in ipairs(r)
   do
      local o = self.rh[s]
      if o
      then
         self:d('providing read callback to', o)
         self:a(o.callback, 'no callback for', o)
         o:callback()
      end
   end
   for _, s in ipairs(w)
   do
      local o = self.wh[s]
      if o
      then
         self:d('providing write callback to', o)
         self:a(o.callback, 'no callback for', o)
         o:callback()
      end
   end

   -- finally run the timeouts so they have maximal time available.. ;-)
   local now = time()
   self:run_timeouts(now)
end

function ssloop:loop()
   self:d('loop')
   self:a(not self.running, 'already running')
   self.stopping = false
   self.running = true
   mst.pcall_and_finally(function ()
                               while not self.stopping
                               do
                                  -- just iterate through the poll loop 'forever'
                                  self:poll()
                               end
                            end,
                            function ()
                               self.running = false
                            end)
end

function ssloop:unloop()
   self.stopping = true
end

function ssloop:run_timeouts(now)
   local c = 0

   self:a(now, 'now mandatory in run_timeouts')
   for i, v in ipairs(self.t)
   do
      if v.started and v.timeout <= now
      then
         self:d('running timeout', v)
         self:a(v.callback, 'no callback for', v)
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

   self:a(now, 'now mandatory in next_timeout')
   for i, v in ipairs(self.t)
   do
      -- ignore if it's not started
      if v.started
      then
         -- there shouldn't be any with v.timeout <= now 
         self:a(v.timeout, 'timeout not set')


         self:a(v.timeout > now, "timeout in past?")
         local d = v.timeout - now
         if not best or best > d
         then
            best = d
         end
      end
   end
   return best
end

function ssloop:done()
   -- make sure that _everything_ is gone
   while #self.r > 0
   do
      self.rh[self.r[1]]:done()
   end
   while #self.w > 0
   do
      self.wh[self.w[1]]:done()
   end
   while #self.t > 0
   do
      self.t[1]:done()
   end
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

--- assorted testing utilities

TEST_TIMEOUT_INVALID=0.5

function run_loop_awhile(timeout)
   local l = loop()
   timeout = timeout or TEST_TIMEOUT_INVALID
   local t = l:new_timeout_delta(timeout,
                                 function ()
                                    l:unloop()
                                 end, timeout)
   t:start()
   l:loop()
   -- whether timeout triggered or not, it should be gone
   t:done()
end

function inject_snitch(o, n, sf)
   local f = o[n]
   o[n] = function (...)
      sf(...)
      f(...)
   end
end

function inject_refcounted_terminator(o, n, c)
   local l = loop()
   local terminator = function ()
      c[1] = c[1] - 1
      if c[1] == 0
      then
         l:unloop()
      end
   end
   inject_snitch(o, n, terminator)
end

function add_eventloop_terminator(o, n)
   local c = {1}
   inject_refcounted_terminator(o, n, c)
end

