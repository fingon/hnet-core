#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: skv.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Tue Sep 18 12:23:19 2012 mstenber
-- Last modified: Sun Nov  4 01:54:53 2012 mstenber
-- Edit time:     370 min
--

require 'mst'
require 'ssloop'
require 'scb'
require 'jsoncodec'

module(..., package.seeall)

-- SMC-generated state machine
-- fix braindeath of using pcall in a state machine in general..
-- and not returning errors in particular
local orig_pcall = pcall
function pcall(f)
   -- errors, huh?
   f()
end
sm = require 'skv_sm'
pcall = orig_pcall


skv = mst.create_class{mandatory={"long_lived"}, class="skv"}
skvconnection = mst.create_class{mandatory={"s", "parent"}, class="skvconnection"}

-- first, skv

skv.__index = skv

local HOST = '127.0.0.1'
local PORT = 12345
local MSG_VERSION = 'version'
local MSG_ID = 'id'
local MSG_UPDATE = 'update'
local MSG_ACK = 'id-ack'
local SKV_VERSION = '1.0'

function skv:init()
   self.change_events = mst.multimap:new{}

   self.local_state = mst.map:new{}
   self.remote_state = {}
   self.host = self.host or HOST
   self.port = self.port or PORT
   self.fsm = sm:new({owner=self})
   self.fsm.debugFlag = true
   self.fsm.debugStream = {write=function (f, s)
                              self:d(mst.string_strip(s))
                                 end}
   self.sent_update_id = 0
   self.acked_id = 0
   self.fsm:enterStartState()
   self:d('init done')
end

function skv:uninit()
   self:d('uninit started')

   self:clear_socket_maybe()
   self:clear_timeout_maybe()
   if self.json
   then
      self:clear_json()
   end

   -- kill dangling skv clients also
   for c, _ in pairs(self.connections or {})
   do
      c:done()
   end
   self:a(not self.connections or self.connections:is_empty())
end

function skv:add_change_observer(cb, k)
   k = k or true
   self.change_events:insert(k, cb)
end

function skv:remove_change_observer(cb, k)
   k = k or true
   self.change_events:remove(k, cb)
end

function skv:change_occured(k, v)
   assert(k and k ~= true)

   for i, o in ipairs(self.change_events[k] or {})
   do
      o(k, v)
   end

   for i, o in ipairs(self.change_events[true] or {})
   do
      o(k, v)
   end
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
   local dead = self._is_done
   return mst.repr{h=self.host, 
                   p=self.port, 
                   st=r, 
                   d=dead,
                  }
end

-- Client code

function skv:init_client(listen_timeout)
   self.listen_timeout = listen_timeout
   self.fsm:Initialized()
end

function skv:is_long_lived()
   return self.long_lived
end

function skv:is_server()
   return self.server
end

function skv:should_auto_retry()
   return not self:is_long_lived() and self.auto_retry
end

function skv:socket_connect()
   self.client = true
   self.connected = false
   self:d('skv:socket_connect')
   self:a(not self.s)
   self.s = scb.new_connect{p=self,
                            host=self.host, port=self.port,
                            debug=self.debug,
                            callback=function (c) 
                               self:d('connect callback')
                               if c
                               then
                                  self.connected = true
                                  -- get rid of old (it may not even exist)
                                  -- (if connect happened synchronously)
                                  self:a(self.s ~= c)
                                  if self.s
                                  then
                                     self.s:detach()
                                     self:clear_socket()
                                  end
                                  self:d('set new socket [connect]')
                                  self.s = c 
                                  c.close_callback = function (s)
                                     self.fsm:ConnectionClosed()
                                  end
                                  self.fsm:Connected()
                               else
                                  self.fsm:ConnectFailed()
                               end
                            end}
   self:d('leaving connect', self.s)

end

-- these clear functions assert, to make sure the state is consistent

function skv:clear_timeout()
   self:a(self.timeout)
   self.timeout:done()
   self.timeout = nil
end

function skv:clear_timeout_maybe()
   if self.timeout
   then
      self:clear_timeout()
   end
end

function skv:clear_socket()
   self:d('cleared socket')
   self:a(self.s)
   self.s:done()
   self.s = nil
end

function skv:clear_socket_maybe()
   if self.s
   then
      self:clear_socket()
   end
end

function skv:clear_json()
   self:a(self.json)
   self.json:done()
   self.json = nil
end


function skv:get_combined_state()
   -- combine both remote and local state. trivial solution: use
   -- table_copy() to create shallow copy table of remote state, and
   -- then update it with local state
   local state = mst.table_copy(self.remote_state)
   mst.table_copy(self.local_state, state)
   return state
end

function skv:send_update(d)
   self.sent_update_id = self.sent_update_id + 1
   self.json:write{[MSG_UPDATE] = d, [MSG_ID]=self.sent_update_id}
end

function skv:send_local_state()
   -- send contents of 'local' to given socket
   if not mst.table_is_empty(self.local_state)
   then
      self:send_update(self.local_state)
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
         self.fsm:ReceiveUpdate(self.json, k, v)
      end
   end
   local id = d[MSG_ID]
   if id
   then
      -- store the last received id - these should be monotonically increasing
      self:a(not self.last_id or self.last_id == (id - 1), 'not monotonically increasing', self.last_id, id)
      self.last_id = id

      self.json:write{[MSG_ACK]=id}
   end
   local id = d[MSG_ACK]
   if id
   then
      self.acked_id = id
   end
end

-- clear all
function skv:clear()
   for i, k in ipairs(self.local_state:keys())
   do
      self:set(k, false)
   end
end

function skv:get(k)
   -- local state overrides remote state
   return self.local_state[k] or self.remote_state[k]
end

function skv:set(k, v)
   self:d('set', k, v)
   if mst.repr_equal(self.local_state[k], v)
   then
      self:d(' .. redundant, local state already matches')
      return
   end
   
   -- let sm have it (either store it, or store+forward)
   self.fsm:HaveUpdate(k, v)

   -- local changes should also trigger change notifications
   -- (may be multiple users on this skv object)
   self:change_occured(k, v)

   return true
end

function skv:store_local_update(k, v)
   self:d('store_local_update', k, v)
   self.local_state[k] = v
end

function skv:send_update_kv(k, v)
   self:d('send_update', k, v)
   self:send_update{[k]=v}
end

function skv:send_update_to_clients(k, v)
   self:d('send_update_to_clients', k, v)
   for c, _ in pairs(self.connections)
   do
      c.json:write{[MSG_UPDATE] = {[k] = v}}
   end
end



function skv:client_remote_update(json, k, v)
   local ov = self:get(k)
   self.remote_state[k] = v
   local lv = self.local_state[k]
   if lv and not mst.repr_equal(lv, v)
   then
      mst.d('remote attempted to update with old value - sending back', k)
      -- local just overrides remote provided value
      self:send_update{[k]=lv}
      return
   end
   if not mst.repr_equal(ov, v)
   then
      self:change_occured(k, v)
   end
end

function skv:server_remote_update(json, k, v)
   local ov = self:get(k)
   -- if remote state was already same, skip
   if mst.repr_equal(self.remote_state[k], v)
   then
      return
   end
   
   -- if we have local state on 'k', skip forwarding and discard
   -- remote state we may have
   lv = self.local_state[k]
   if self.local_state[k]
   then
      -- if local state is different than what we got from remote,
      -- update remote
      if not mst.repr_equal(lv, v)
      then
         json:write{[MSG_UPDATE] = {[k] = lv}}
      end
      self.remote_state[k] = nil
      return
   end

   if not mst.repr_equal(ov, v)
   then
      self:change_occured(k, v)
   end

   -- update remote state
   self.remote_state[k] = v

   self:send_update_to_clients(k, v)
end





function skv:wrap_socket_json()
   self:d('wrap_socket_json', self.s)
   self:a(not self.json, 'already have json')
   self:a(self.s, 'no socket to wrap')
   self.json = jsoncodec.wrap_socket{s=self.s, 
                                     debug=self.debug,
                                     callback=function (o)
                                        self:handle_received_json(o)
                                     end,
                                     close_callback=function ()
                                        self.fsm:ConnectionClosed()
                                     end}
   
   self.s = nil
end

function skv:get_jsoncodecs()
   -- hopefully just one in case of client
   if self.json
   then
      return {self.json}
   end

   -- in case of server, we have to look at the server connections
   local rl = {}
   for k, v in pairs(self.connections or {})
   do
      table.insert(rl, k.json)
   end
   return rl
end


--- synchronously connect to another skv instance
-- return once we've received state from there
-- optionally use the timeout to fail..
-- return value is 'true' if connection succeeds; non-true
-- (timeout/error in the second parameter)
function skv:connect(timeout)
   self:a(not self.long_lived)
   local l = ssloop.loop()
   local r, err
   local tr = l:loop_until(function ()
                              local st = self.fsm:getState().name
                              if st == 'Client.WaitUpdates'
                              then
                                 r = true
                                 return true
                              elseif st == 'Terminal.ClientFailConnect'
                              then
                                 err = 'unable to connect'
                                 return true
                              end
                           end, timeout)
   if not tr
   then
      err = 'timeout'
   end
   return r, err
end

function skv:wait_in_sync(timeout)
   self:a(not self.long_lived)
   local l = ssloop.loop()
   local tr = l:loop_until(function ()
                              return self.acked_id == self.sent_update_id
                           end, timeout)
   if not tr then return nil, 'timeout' end
   return tr
end

-- Server code

function skv:init_server()
   self.fsm:Initialized()
   self.client = false
   self.connections = mst.set:new()
end

function skv:bind()
   local s, err = scb.new_listener{p=self,
                                   host=self.host, port=self.port, 
                                   debug=self.debug,
                                   callback=function (c) 
                                      self:new_client(c)
                                   end}
   if s
   then
      self:a(not self.s)
      self.s = s
      self.fsm:Bound()
      return
   else
         self.fsm:BindFailed()
   end
end

function skv:new_client(s)
   skvconnection:new{s=s, parent=self, debug=self.debug}
end

function skv:increase_retry_timer()
   -- 1.5x every time.. should eventually behave reasonably
   self.listen_timeout = self.listen_timeout * 3 / 2
end

function skv:start_retry_timer(timeout)
   timeout = timeout or self.listen_timeout
   local l = ssloop.loop()
   self:a(not self.timeout, 'previous timeout around')
   self.timeout = l:new_timeout_delta(timeout,
                                      function ()
                                         self.fsm:Timeout()
                                      end):start()
end

-- Server's single client side connection handling

function skvconnection:init()
   assert(self)
   self.parent.connections[self] = true
   self:a(not self.json)
   self.json = jsoncodec.wrap_socket{s=self.s,
                                     debug=self.debug,
                                     callback=function (o)
                                        self:handle_received_json(o)
                                     end,
                                     close_callback=function ()
                                        self:handle_close()
                                     end
                                    }
   self.s = nil

   -- send version
   -- and the local+remote state if any
   local state = self.parent:get_combined_state()

   self.json:write{[MSG_VERSION] = SKV_VERSION,
                   [MSG_UPDATE] = state}
end

function skvconnection:uninit()
   self:a(self.parent.connections[self] ~= nil, ":done - not in parent table")
   self.parent.connections[self] = nil
   self.json:done()
end

function skvconnection:handle_received_json(d)
   self:d('handle_received_json', d)

   local uh = d[MSG_UPDATE]
   if uh
   then
      -- contains dictionary
      for k, v in pairs(uh)
      do
         self.parent.fsm:ReceiveUpdate(self.json, k, v)
      end
   end
   
   local id = d[MSG_ID]
   if id
   then
      -- store the last received id - these should be monotonically increasing
      self:a(not self.last_id or self.last_id == (id - 1), 'not monotonically increasing', self.last_id, id)
      self.last_id = id

      -- ack client id's
      self.json:write{[MSG_ACK]=id}
   end
end

function skvconnection:handle_close()
   self:d('handle_close')
   self:done()
end

function skvconnection:repr_data()
   return '?'
end
