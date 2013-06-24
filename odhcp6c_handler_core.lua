#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: odhcp6c_handler_core.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Mar 25 18:25:10 2013 mstenber
-- Last modified: Mon Jun 24 14:03:26 2013 mstenber
-- Edit time:     28 min
--

-- This is rather minimal core handling code, which takes (using
-- environment variables / arguments) configuration from odhcp6c, and
-- then sets the skv variables appropriately.

-- Instead of a shell script, the Lua script seems much, much easier
-- to handle and therefore that's what we use here. Hopefully this
-- assumption is true :)

require 'mst'
require 'skvtool_core'
require 'elsa_pa'

module(..., package.seeall)

ohc = mst.create_class{class='ohc', mandatory={'getenv', 'args', 'skv', 'time'}}

offline_states = mst.array_to_table{'unbound', 'stopped'}

ENV_RDNSS='RDNSS' -- space-separated dns server list
ENV_DOMAINS='DOMAINS' -- space-separated dns search list
ENV_PREFIXES='PREFIXES' -- list of prefixes from PD
ENV_RA_ROUTES='ROUTES' -- RA routes

function ohc:split_from_env(varname, x)
   local v = self.getenv(varname)
   if not v
   then
      return {}
   end
   return mst.string_split(v, x)
end

-- create single pd.<ifname> array, which contains both the PD
-- prefixes, and the name server information gleaned from the odhcp6c.
function ohc:create_skv_prefix_array(state)
   local p = mst.array:new{}
   
   self:d('create_skv_prefix_array')

   -- if it's in offline state, stop publishing anything whatsoever
   -- (even if some lifetime is left). the underlying assumption is
   -- that we have retried a bit, and haven't gotten response or
   -- whatever, and we shouldn't publish anything (delayed depracation
   -- etc still applies).
   if offline_states[state]
   then
      return p
   end

   local now = self.time()

   for i, v in ipairs(self:split_from_env(ENV_PREFIXES, ' '))
   do
      local l = mst.string_split(v, ',', 4)
      mst.a(#l >= 3 and #l <= 4)
      local prefix, pref, valid, rest = unpack(l)
      -- first 3 parts are mandatory; last one isn't
      local pclass
      if rest and #rest > 0
      then
         for i, s in ipairs(mst.string_split(rest, ','))
         do
            local sl = mst.string_split(s, '=', 2)
            self:a(#sl == 2, 'invalid optional argument', s)
            k, v = unpack(sl)
            if k == 'class'
            then
               pclass = tonumber(v)
            end
         end
      end
      pref = tonumber(pref)
      valid = tonumber(valid)
      local o = {[elsa_pa.PREFIX_KEY]=prefix,
                 [elsa_pa.VALID_KEY]=valid+now,
                 [elsa_pa.PREFERRED_KEY]=pref+now,
                 [elsa_pa.PREFIX_CLASS_KEY]=pclass,
      }
      self:d(' adding prefix', v, o)
      p:insert(o)
   end

   -- if there are no valid prefixes on the interface, we're not
   -- interested about DNS information - most likely it's provided by
   -- OUR stateless dhcpv6 code!
   if #p == 0
   then
      return p
   end

   for i, v in ipairs(self:split_from_env(ENV_RDNSS, ' '))
   do
      self:d(' adding dns server', v)
      p:insert{[elsa_pa.DNS_KEY]=v}
   end

   for i, v in ipairs(self:split_from_env(ENV_DOMAINS, ' '))
   do
      self:d(' adding search path', v)

      p:insert{[elsa_pa.DNS_SEARCH_KEY]=v}
   end

   return p
end

function ohc:run()
   mst.a(#self.args == 2)

   -- the script should be called with two arguments: interface name, and
   -- state
   local ifname, state = unpack(self.args)

   local p = self:create_skv_prefix_array(state)
   local key = elsa_pa.PD_SKVPREFIX .. ifname
   self.skv:set(key, p)
   --self.skv:wait_in_sync()
end
