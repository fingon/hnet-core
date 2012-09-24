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
-- Last modified: Mon Sep 24 16:10:58 2012 mstenber
-- Edit time:     224 min
--

require 'mst'
require 'ssloop'
require 'scb'
require 'jsoncodec'

-- SMC-generated state machine
-- fix braindeath of using pcall in a state machine in general..
-- and not returning errors in particular
local orig_pcall = pcall
function pcall(f)
   -- errors, huh?
   f()
end
local sm = require 'skv_sm'
pcall = orig_pcall

module(..., package.seeall)

skv = mst.create_class{mandatory={"long_lived"}, class="skv"}
skvclient = mst.create_class{mandatory={"s", "parent"}, class="skvclient"}

-- first, skv

skv.__index = skv

local HOST = '127.0.0.1'
local PORT = 12345
local CONNECT_TIMEOUT = 0.1
local INITIAL_LISTEN_TIMEOUT = 0.2
local MSG_VERSION = 'version'
local MSG_UPDATE = 'update'
local SKV_VERSION = '1.0'

function skv:init()
   self.local_state = {}
   self.remote_state = {}
   self.host = self.host or HOST
   self.port = self.port or PORT
   if self.debug
   then
      --local f = iself.open('x.log', 'w')
      self.fsm = sm:new({owner=self, debugFlag=true})
   else
      self.fsm = sm:new({owner=self})
   end
   self.fsm:enterStartState()
end

-- we're done with the object -> clear state
function skv:done()
   if self.s
   then
      self.s:done()
      self.s = nil
   end
   self:clear_ev()
end

function skv:fail(s)
   self.error = s
   if self.debug
   then
      error(s)
   end
end

function skv:repr_data()
   if self.fsm
   then
      -- make sure state is accesssible
      r, err = pcall(function () self.fsm:getState() end)
      if not r
      then
         r = "?"
      else
         r = self.fsm:getState().name
      end
   else
      r = "!"
   end
   return string.format('host:%s port:%d state:%s', 
                        self.host or "?", 
                        self.port or 0, 
                        r)
end

-- Client code

function skv:init_client()
   self.listen_timeout = INITIAL_LISTEN_TIMEOUT
   self.fsm:Initialized()
end

function skv:is_long_lived()
   return self.long_lived
end

function skv:should_auto_retry()
   return not self:is_long_lived() and self.auto_retry
end

function skv:connect()
   self.client = true
   self.connected = false
   self:d('skv:connect')
   self.s = scb.new_connect{host=self.host, port=self.port,
                               debug=self.debug,
                               callback=function (c) 
                                  self:d('connect callback')
                                  if c
                                  then
                                     self.connected = true
                                     self.s = c
                                     c.close_callback = function (s)
                                        self.fsm:ConnectionClosed()
                                     end
                                     self.fsm:Connected()
                                  else
                                     self.s:done()
                                     self.s = nil
                                     self.fsm:ConnectFailed()
                                  end
                               end}
   if not self.connected
   then
      local l = ssloop.loop()
      self.s_t = l:new_timeout_delta(CONNECT_TIMEOUT,
                                     function ()
                                        self:d('!!t1!!')
                                        self.fsm:ConnectFailed()
                                     end):start()
   end
end

function skv:clear_ev()
   -- kill listeners, if any
   local c = 0
   self:d('clear_ev')
   for _, e in ipairs({"s_w", "s_t", "s_r"})
   do
      if self[e]
      then
         self:d(' removing', e, self[e])
         o = self[e]
         o:stop()
         self[e] = nil
         c = c + 1
      end
   end
end

function skv:get_combined_state()
   -- combine both remote and local state. trivial solution: use
   -- table_copy() to create shallow copy table of remote state, and
   -- then update it with local state
   local state = mst.table_copy(self.remote_state)
   mst.table_copy(self.local_state, state)
   return state
end

function skv:send_local_state(s)
   -- send contents of 'local' to given socket (or our socket)
   local dest = s or self.s
   if not mst.table_is_empty(self.local_state)
   then
      dest:write{[MSG_UPDATE] = self.local_state}
   end
end

function skv:protocol_is_current_version(v)
   return v == SKV_VERSION
end

function skv:handle_received_json(d)
   -- handle received datastructure from json blob
   -- must be a table
   self:d('handle_received_json', d)
   if type(d) ~= 'table'
   then
      self:d('got wierd typed data', type(d))
      return
   end
   -- is it version? if so, dispatch that
   local v = d[MSG_VERSION]
   if v
   then
      self:d('got version', v)
      self.fsm:ReceiveVersion(v)
   end
   local uh = d[MSG_UPDATE]
   if uh
   then
      -- contains dictionary
      for k, v in pairs(uh)
      do
         self.fsm:HaveUpdate(k, v)
      end
   end
end

function skv:get(k)
   -- local state overrides remote state
   local v = self.local_state[k]
   if v
   then
      return v
   end
   return self.remote_state[k]
end

function skv:set(k, v)
   self:d('set', k, v)
   self.fsm:HaveUpdate(k, v)
end

function skv:store_local_update(k, v)
   self:d('store_local_update', k, v)
   self.local_state[k] = v
end

function skv:send_update(k, v)
   self:d('send_update', k, v)
   self.s:write{[MSG_UPDATE] = {[k] = v}}
end

function skv:send_update_to_clients(k, v)
   self:d('send_update_to_clients', k, v)
   for c, _ in pairs(self.connections)
   do
      c.s:write{[MSG_UPDATE] = {[k] = v}}
   end
end



function skv:store_remote_update(k, v)
   self.remote_state[k] = v
end

function skv:wrap_socket_jsoncodec()
   -- clear existing listeners, json will install it's own
   self:clear_ev()

   self.s = jsoncodec.wrap_socket{s=self.s, 
                                  debug=self.debug,
                                  callback=function (o)
                                     self:handle_received_json(o)
                                  end,
                                  close_callback=function ()
                                     self.fsm:ConnectionClosed()
                                  end}
end

function skv:clear_jsoncodec()
   self.s:done()
   self.s = nil
end

-- Server code

function skv:init_server()
   self.fsm:Initialized()
   self.client = false
   self.connections = {}
end

function skv:bind()
   s, err = scb.new_listener{host=self.host, port=self.port, 
                                debug=self.debug,
                                callback=function (c) 
                                   self:new_client(c)
                                end}
   if s
   then
      self.s = s
      self.fsm:Bound()
      return
   else
      self.fsm:BindFailed()
   end
end

function skv:new_client(s)
   skvclient:new{s=s, parent=self, debug=self.debug}
end

function skv:increase_retry_timer()
   -- 1.5x every time.. should eventually behave reasonably
   self.listen_timeout = self.listen_timeout * 3 / 2
end

function skv:start_retry_timer()
   local l = ssloop.loop()
   self.s_t = l:new_timeout_delta(CONNECT_TIMEOUT,
                                  function ()
                                     self:d('!!t2!!')
                                     self:clear_ev()
                                     self.fsm:Timeout()
                                  end):start()
end

-- Server's single client side connection handling

function skvclient:init()
   self.is_done = false
   assert(self)
   self.parent.connections[self] = true
   self.s = jsoncodec.wrap_socket{s=self.s,
                                  debug=self.debug,
                                  callback=function (o)
                                     self:handle_received_json(o)
                                  end,
                                  close_callback=function ()
                                     self:handle_close()
                                  end
                                 }
   -- send version
   self.s:write{[MSG_VERSION] = SKV_VERSION}
   -- and the local+remote state if any
   local state = self.parent:get_combined_state()

   if not mst.table_is_empty(state)
   then
      self.s:write{[MSG_UPDATE] = state}
   end
end

function skvclient:handle_received_json(d)
   self:d('handle_received_json', d)

   local uh = d[MSG_UPDATE]
   if uh
   then
      -- contains dictionary
      for k, v in pairs(uh)
      do
         self.parent.fsm:HaveUpdate(k, v)
      end
   end
end

function skvclient:handle_close()
   self:done()
end

function skvclient:repr_data()
   return '?'
end

function skvclient:done()
   if not self.is_done
   then
      self.is_done = true
      self:a(self.parent.connections[self] ~= nil, ":done - not in parent table")
      self.parent.connections[self] = nil
      self.s:done()
   end
end
