#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv6s.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
--  Copyright (c) 2012 Markus Stenberg
--       All rights reserved
--
-- Created:       Mon Oct  1 21:59:03 2012 mstenber
-- Last modified: Tue Oct  2 13:42:35 2012 mstenber
-- Edit time:     16 min
--

require 'mst'

module(..., package.seeall)

-- ipv6 handling stuff
function ascii_cleanup_sub(nl, si, ei, r)
   for i=si,ei
   do
      table.insert(r, string.format("%x", nl[i]))
   end
end

function ascii_cleanup(s)
   local sl = mst.string_split(s, ':')
   local nl = mst.array_map(sl, function (x) return mst.strtol(x, 16) end)
   local best = false
   for i, v in ipairs(nl)
   do
      if v == 0
      then
         local ml = 1
         for j = i+1, #nl
         do
            if nl[j] == 0
            then
               ml = ml + 1
            else
               break
            end
         end
         if not best or best[1] < ml
         then
            best = {ml, i}
         end
      end
   end
   local r = {}
   if best
   then
      ascii_cleanup_sub(nl, 1, best[2]-1, r)
      table.insert(r, '')
      if best[1]+best[2] >  #nl
      then
         table.insert(r, '')
      else
         ascii_cleanup_sub(nl, best[1]+best[2], #nl, r)
      end
   else
      ascii_cleanup_sub(nl, 1, #nl, r)
   end
   return table.concat(r, ":")
end

function binary_to_ascii(b)
   mst.a(type(b) == 'string', 'non-string input to binary_to_ascii', b)
   --assert(#b % 4 == 0, 'non-int size')
   local t = {}
   -- let's assume we're given ipv6 address in binary. convert it to ascii
   for i, c in mst.string_ipairs(b)
   do
      local b = string.byte(c)
      if i % 2 == 1 and i > 1
      then
         table.insert(t, ':')
      end
      table.insert(t, string.format('%02x', b))
   end
   return ascii_cleanup(table.concat(t))
end

local _null = string.char(0)

function ascii_to_binary(b)
   mst.a(type(b) == 'string', 'non-string input to ascii_to_binary', b)
   -- let us assume it is in standard XXXX:YYYY:ZZZZ: format, with
   -- potentially one ::
   local l = mst.string_split(b, ":")
   --mst.d('ascii_to_binary', l)

   mst.a(#l <= 8) 
   local idx = false
   for i, v in ipairs(l)
   do
      if #v == 0
      then
         mst.a(not idx or (idx == i-1 and i == #l), "multiple ::s")
         if not idx
         then
            idx = i
            --mst.d('found magic index', idx)
         end
      end
   end
   local t = {}
   for i, v in ipairs(l)
   do
      if i == idx
      then
         local _pad=(9-#l)
         --mst.d('padding', _pad)
         for _=1,_pad
         do
            -- dump few magic 0000's 
            table.insert(t, _null .. _null)
         end
      else
         local n, err = mst.strtol(v, 16)
         mst.a(n, 'error in strtol', err)
         table.insert(t, string.char(math.floor(n / 256)) .. string.char(n % 256))
      end
   end
   return table.concat(t)
end


-- convert prefix to binary address blob with only relevant bits included
function prefix_to_bin(p)
   local l = mst.string_split(p, '/')
   mst.a(#l == 2, 'invalid prefix', p)
   mst.a(l[2] % 8 == 0, 'bit-based prefix length handling not supported yet')
   local b = ascii_to_binary(l[1])
   return string.sub(b, 1, l[2] / 8)
end

function prefix_contains(p1, p2)
   mst.a(p1 and p2, 'invalid arguments to prefix_contains', p1, p2)
   local b1 = prefix_to_bin(p1)
   local b2 = prefix_to_bin(p2)
   if #b1 > #b2
   then
      return false
   end
   -- #b1 <= #b2 if p1 contains p2
   return string.sub(b2, 1, #b1) == b1
end

function binary_prefix_next_from_usp(up, p)
   mst.a(#p == 8)
   mst.a(#b <= 8)
   if #b == 8
   then
      mst.a(b == p)
      return p
   end
   -- two different cases - either prefix+1 is still within up => ok,
   -- or it's not => start from zeros
   local pb = {string.byte(p, 1, #p)}
   for i=8, 1, -1
   do
      pb[i] = (pb[i] + 1) % 256
      if pb[i]
      then
         break
      end
   end
   local p2 = string.char(unpack(pb))
   if string.sub(p2, 1, #up) == up
   then
      return p2
   end
   return up .. string.rep(string.char(0), 8 - #up)
end

