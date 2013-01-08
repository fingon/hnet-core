#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv4s.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Tue Jan  8 12:54:54 2013 mstenber
-- Last modified: Tue Jan  8 13:06:22 2013 mstenber
-- Edit time:     4 min
--

-- Minimalist mirror image of ipv6s, with similar API. This should
-- probably in truth use some general API, but as these bits-n-pieces
-- worked in IPv4-in-IPv6 parser in ipv6s, they do also work
-- standalone..

module(..., package.seeall)

function address_to_binary_address(s)
   -- IPv4 address most likely
   local l = mst.string_split(s, ".")
   --mst.d('no : found', l)
   if #l == 4
   then
      return table.concat(l:map(string.char))
   end
   return nil, 'invalid address ' .. tostring(s)
end

function binary_address_to_address(b)
   mst.a(#b == 4)
   local bl = {string.byte(b, 1, 4)}
   mst.a(#bl == 4)
   local sl = mst.array_map(bl, tostring)
   return table.concat(sl, ".")
end
