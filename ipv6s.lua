#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ipv6s.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Mon Oct  1 21:59:03 2012 mstenber
-- Last modified: Sat Oct 27 13:09:34 2012 mstenber
-- Edit time:     107 min
--

require 'mst'

module(..., package.seeall)

-- ULA addresses are just fcXX:*
ula_prefix = string.char(0xFC)

-- 10x 0, 2x ff, 4x IPv4 address
-- ::ffff:1.2.3.4
local mapped_ipv4_prefix = string.rep(string.char(0), 10) .. string.rep(string.char(0xFF), 2) 


-- ipv6 handling stuff
function address_cleanup_sub(nl, si, ei, r)
   for i=si,ei
   do
      table.insert(r, string.format("%x", nl[i]))
   end
end

function address_cleanup(s)
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
      address_cleanup_sub(nl, 1, best[2]-1, r)
      table.insert(r, '')
      if best[1]+best[2] >  #nl
      then
         table.insert(r, '')
      else
         address_cleanup_sub(nl, best[1]+best[2], #nl, r)
      end
   else
      address_cleanup_sub(nl, 1, #nl, r)
   end
   return table.concat(r, ":")
end

function binary_address_to_address(b)
   -- magic handling if it's mapped IPv4 address
   if binary_address_is_ipv4(b) and #b == 16
   then
      -- (we don't handle non-full ones here; if it's from prefix, it
      -- better be padded to full size)
      local bl = {string.byte(b, 13, 16)}
      local sl = mst.array_map(bl, tostring)
      return table.concat(sl, "."), 96
   end

   --mst.d('not v4', mst.string_to_hex(b), #b)
   

   mst.a(type(b) == 'string', 'non-string input to binary_address_to_address', b)
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
   return address_cleanup(table.concat(t))
end

local _null = string.char(0)

function address_to_binary_address(b)
   mst.a(type(b) == 'string', 'non-string input to address_to_binary', b)
   -- let us assume it is in standard XXXX:YYYY:ZZZZ: format, with
   -- potentially one ::
   --mst.d('address_to_binary_address', b)

   local l = mst.string_split(b, ":")
   --mst.d('address_to_binary', l)

   if #l == 1 and string.find(b, ".")
   then
      -- IPv4 address most likely
      local l = mst.string_split(b, ".")
      --mst.d('no : found', l)
      if #l == 4
      then
         local r = mapped_ipv4_prefix .. table.concat(l:map(string.char))
         --mst.d('ipv4', mst.string_to_hex(r))
         return r, 96
      end
   end

   mst.a(#l <= 8) 
   local idx = false
   for i, v in ipairs(l)
   do
      if #v == 0
      then
         mst.a(not idx or (idx == i-1 and i == #l), "multiple ::s", b)
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

-- convert binary prefix to binary address (=add trailing 0's)
function binary_prefix_to_binary_address(b)
   if #b < 16
   then
      return b .. string.rep(string.char(0), 16-#b)
   end
   mst.a(#b == 16)
   return b
end


-- convert prefix to binary address blob with only relevant bits included
function prefix_to_binary_prefix(p)
   local l = mst.string_split(p, '/')
   mst.a(#l == 2, 'invalid prefix (no prefix length)', p)
   mst.a(l[2] % 8 == 0, 'bit-based prefix length handling not supported yet')
   local b, add_bits = address_to_binary_address(l[1])
   l[2] = l[2] + (add_bits or 0)
   return string.sub(b, 1, l[2] / 8)
end

-- assume that everything within is actually relevant
function binary_prefix_to_prefix(bin)
   local bits = #bin * 8
   local bin = binary_prefix_to_binary_address(bin)
   local a, remove_bits = binary_address_to_address(bin)
   bits = bits - (remove_bits or 0)
   return string.format('%s/%d', a, bits)
end

function binary_prefix_contains(b1, b2)
   mst.a(b1 and b2, 'invalid arguments to binary_prefix_contains', b1, b2)
   if #b1 > #b2
   then
      return false
   end
   -- #b1 <= #b2 if p1 contains p2
   return string.sub(b2, 1, #b1) == b1
end

function prefix_contains(p1, p2)
   mst.a(p1 and p2, 'invalid arguments to prefix_contains', p1, p2)
   local b1 = prefix_to_binary_prefix(p1)
   local b2 = prefix_to_binary_prefix(p2)
   return binary_prefix_contains(b1, b2)
end

function binary_prefix_next_from_usp(b, p, desired_bits)
   mst.a(#p == desired_bits/8)
   mst.a(#b <= desired_bits/8)
   if #b == desired_bits/8
   then
      mst.a(b == p)
      return p
   end
   -- two different cases - either prefix+1 is still within up => ok,
   -- or it's not => start from zeros
   local pb = {string.byte(p, 1, #p)}
   for i=desired_bits/8, 1, -1
   do
      pb[i] = (pb[i] + 1) % 256
      if pb[i]
      then
         break
      end
   end
   local p2 = string.char(unpack(pb))
   if string.sub(p2, 1, #b) == b
   then
      return p2
   end
   return b .. string.rep(string.char(0), desired_bits/8 - #b)
end

-- given the hwaddr (in normal aa:bb:cc:dd:ee:ff:aa format) and
-- prefix, generate eui64 masked address (e.g. addr/64)
function prefix_hwaddr_to_eui64(prefix, hwaddr)
   -- start is easy - prefix as binary
   local bp = prefix_to_binary_prefix(prefix)
   mst.a(#bp == 8, 'invalid base prefix')
   -- then, generat binary representation of hw hwaddr.. which is bit depressing
   local t = mst.string_split(hwaddr, ':')
   mst.a(#t == 6, 'invalid hwaddr', #t, hwaddr)
   local hwa = t:map(function (x) return mst.strtol(x, 16) end)

   -- xor the globally unique bit
   hwa[1] = mst.bitv_xor_bit(hwa[1], 2)
   
   -- then insert the first 3 characters
   local hwn = hwa:slice(1, 3)
   -- then ff, fe
   hwn:extend({0xff, 0xfe})
   -- and then last 3 characters from hw address
   hwn:extend(hwa:slice(4, 6))
   local hwb = string.char(unpack(hwn))
   local b = bp .. hwb
   return binary_address_to_address(b) .. '/64'
end

function prefix_bits(addr)
   local a = mst.string_split(addr, '/')
   mst.a(#a == 2)
   local bits = mst.strtol(a[2], 10)
   mst.a(bits >= 0 and bits <= 128)
   return bits
end

-- OO approach - object

ipv6_prefix = mst.create_class{class='ipv6_prefix'}

function ipv6_prefix:init()
   -- must have EITHER ascii or binary representation to start with!
   self:a(self.ascii or self.binary)
end

function ipv6_prefix:get_ascii()
   if not self.ascii
   then
      self:a(self.binary)
      self.ascii = binary_prefix_to_prefix(self.binary)
   end
   return self.ascii
end

function ipv6_prefix:clear_tailing_bits()
   -- basically, convert ascii => binary (stores only relevant bits)
   self:get_binary()

   -- then clear ascii, regenerate it from new binary as needed
   self.ascii = nil
end

function ipv6_prefix:get_binary()
   if not self.binary
   then
      self:a(self.ascii)
      self.binary = prefix_to_binary_prefix(self.ascii)
   end
   return self.binary
end

function ipv6_prefix:get_binary_bits()
   if self.binary_bits then return self.binary_bits end
   return #self:get_binary() * 8
end

function binary_address_is_ula(b)
   return string.sub(b, 1, #ula_prefix) == ula_prefix

end

function ipv6_prefix:is_ula()
   return binary_address_is_ula(self:get_binary())
end

function binary_address_is_ipv4(b)
   return string.sub(b, 1, #mapped_ipv4_prefix) == mapped_ipv4_prefix
end

function ipv6_prefix:is_ipv4()
   return binary_address_is_ipv4(self:get_binary())
end


function ipv6_prefix:repr()
   return mst.repr(self:get_ascii())
end


function ipv6_prefix:contains(p2)
   return prefix_contains(self:get_ascii(), p2:get_ascii())
end

function new_prefix_from_ascii(s)
   return ipv6_prefix:new{ascii=s}
end

function new_prefix_from_binary(b, binary_bits)
   return ipv6_prefix:new{binary=b, binary_bits=binary_bits}
end

