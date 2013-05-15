#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_client.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu May  9 12:26:36 2013 mstenber
-- Last modified: Thu May  9 15:22:40 2013 mstenber
-- Edit time:     32 min
--

-- This is purely read-only version of mdns code. It leverages
-- mdns_core (and therefore mdns_if), but it does not attempt to
-- propagate any information whatsoever. This is done adding NOP
-- queue_check_propagate_if_rr in the mdns_client class.

-- Instead, ~synchronous (see scr.lua) interface using coroutines is
-- provided, which under the hood maps to mdns_client running within
-- ssloop, and it's results being polled every now and then.

-- Events are used to notice when something related to request _might_
-- be available (and then to do more heavy processing).

-- Assumptions:
--
-- If there's something in cache with CF set, it is the truth and
-- whole truth => We can return that immediately.
--
-- Otherwise, schedule a query, wait until either we get something
-- with CF set (=> respond 'immediately'), or until we time out (0,8
-- seconds). This figure is chosen so that e.g. Windows naming
-- resolution won't give up - it has 1 second timeout for first try.
--
-- => We should provide _something_ for CF records almost immediately,
-- and for non-CF, we have sub-second delay. Tough. (Given LLQ enabled
-- client, we could do this also faster, but we don't currently have
-- any way to make sure of that.)

require 'mst'
require 'mdns_core'
require 'scr'
local _eventful = require 'mst_eventful'.eventful

module(..., package.seeall)

mdns_client_request = _eventful:new_subclass{class='mdns_client_request',
                                             mandatory={'ifo', 'q'}}

function mdns_client_request:init()
   -- superclass init
   _eventful.init(self)
   
   -- hook up to ifo cache change notification stuff; inserted
   -- cache_flush rr's interest us greatly
   self:connect_method(self.ifo.cache.inserted, 
                       self.inserted_cache_rr)

   -- start query
   self.ifo:query(self.q)
   
end

function mdns_client_request:inserted_cache_rr(rr)
   if rr.cache_flush
   then
      self:d('inserted_cache_rr (cf)')
      self.had_cf = true
   else
      self:d('inserted_cache_rr (non-cf)')
   end
end

function mdns_client_request:wait_done(timeout)
   local had_cf = function ()
      return self.had_cf
   end
   local t, to = scr.get_timeout(timeout)
   coroutine.yield(had_cf, t)
   -- get rid of timeout object
   if to
   then
      to:done()
   end
end

function mdns_client_request:is_done()
   return self.had_cf or self.had_timeout
end

mdns_client = mdns_core.mdns:new_subclass{class='mdns_client'}

function mdns_client:resolve_ifo_q(ifo, q, cache_flush)
   local r
   self:d('resolve_ifo_q', ifo, q, cache_flush)
   ifo:iterate_matching_query(false,
                              q,
                              nil,
                              function (rr)
                                 self:d(' found', rr)
                                 if not cache_flush or rr.cache_flush
                                 then
                                    r = r or {}
                                    table.insert(r, rr)
                                 end
                              end)
   return r
end

function mdns_client:queue_check_propagate_if_rr(ifname, rr)
   -- we never propagate anything - pure resolver only
   return
end

function mdns_client:resolve_ifname_q(ifname, q, timeout)
   self:d('resolve_ifname_q', ifname, q, timeout)
   local ifo = self:get_if(ifname)
   
   -- immediately check if we have something with cf set true
   local r = self:resolve_ifo_q(ifo, q, true)
   if r
   then
      self:d(' immediate', r)
      return r, true
   end

   -- no such luck, we have to play with mdns_client_request, and wait
   -- up to timeout (or cf entry).
   local o = mdns_client_request:new{ifo=ifo, q=q}
   self:d(' wait_done', timeout)
   o:wait_done(timeout)
   o:done()

   -- now, just dump whatever we have in cache (if anything) as result
   self:d('wait finished, checking cache')

   r = self:resolve_ifo_q(ifo, q)
   self:d('found in cache', nil)

   return r, o.had_cf
end