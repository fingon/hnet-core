#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ssloop.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Sep 20 11:24:12 2012 mstenber
-- Last modified: Mon Oct 29 21:47:44 2012 mstenber
-- Edit time:     126 min
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
local mstwrapper = mst.create_class{started=false, class='mstwrapper'}

function mstwrapper:uninit()
   self:d('uninit')
   -- stop us in case caller didn't
   self:stop()
end

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
   self:d('started')
end

function mstio:raw_stop()
   local l = loop()
   local a = self.reader and l.r or l.w
   local h = self.reader and l.rh or l.wh
   local r = mst.array_remove(a, self.s)
   
   self:a(r, "we were missing from event loop socket list")
   self:a(h[self.s] ~= nil, "we're missing from event loop hash")
   h[self.s] = nil
   self:d('stopped')
end

function mstio:repr_data()
   local fd = self.s:getfd()
   local s = mst.repr{fd=fd, 
                      p=self.p,
                      started=self.started}
   if self.reader
   then
      return 'reader '.. s
   end
   return 'writer '.. s
end

--- msttimeout - wrapper for timeout 

local msttimeout = mstwrapper:new_subclass{mandatory={'timeout', 'callback'},
                                           class='msttimeout'}

function msttimeout:init()
   local l = loop()
   self.started = false
   table.insert(l.t, self)
   self:d('init')

end

function msttimeout:uninit()
   self:d('uninit')
   local l = loop()
   mst.array_remove(l.t, self)
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

function ssloop:uninit()
   self:d('uninit')

   -- clear the handlers, if they're around
   self:clear()
end

function ssloop:repr_data()
   return string.format('#r:%d #w:%d #t:%d', #self.r, #self.w, #self.t)
end

function ssloop:clear()
   self:d('clear')

   local cleared = mst.array:new()
   -- make sure that _everything_ is gone
   -- we gather a list to clear, and then clear it later
   for i, v in ipairs(self.r)
   do
      cleared:insert(self.rh[v])
   end
   for i, v in ipairs(self.w)
   do
      cleared:insert(self.wh[v])
   end
   for i, v in ipairs(self.t)
   do
      cleared:insert(v)
   end
   if cleared:is_empty()
   then
      return
   end
   self:d('clearing', cleared)
   for i, v in ipairs(cleared)
   do
      v:done()
   end
   self:a('unable to clear r', not #self.r)
   self:a('unable to clear w', not #self.w)
   self:a('unable to clear t', not #self.t)
   return cleared
end

function ssloop:new_reader(s, callback, p)
   local o = mstio:new{s=s, callback=callback, reader=true, p=p}
   -- not added anywhere before start()
   self:d('added new reader', o)
   return o
end

function ssloop:new_writer(s, callback, p)
   local o = mstio:new{s=s, callback=callback, reader=false, p=p}
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

-- loop while cond is not true, or timeout hasn't expired. return t if
-- cond changed, and nil if timeout expired.
function ssloop:loop_until(cond, timeout)
   local timeouted = false
   local t
   if timeout
   then
      t = self:new_timeout_delta(timeout, function () timedout = true end)
      t:start()
   end
   while not timeouted
   do
      self:poll()
      if cond()
      then
         break
      end
   end
   if t 
   then
      t:done()
   end
   return not timeouted
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

TEST_TIMEOUT_INVALID=15.0

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

-- convenience API (used by older code) 
function run_loop_until(stmt, timeout)
   local l = loop()
   local r = l:loop_until(stmt, timeout or TEST_TIMEOUT_INVALID)
   if not r
   then
      error("timeout expired")
   end
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

