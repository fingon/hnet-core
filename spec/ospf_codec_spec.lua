#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: ospf_codec_spec.lua $
--
-- Author: Markus Stenberg <fingon@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Thu Sep 27 18:34:49 2012 mstenber
-- Last modified: Wed Jun 19 13:40:06 2013 mstenber
-- Edit time:     54 min
--

require "busted"
require "ospf_codec"

module("ospf_codec_spec", package.seeall)

local tests = {
   -- check that different paddings work
   {ospf_codec.rhf_ac_tlv, {body=string.rep('1', 40)}},
   {ospf_codec.rhf_ac_tlv, {body=string.rep('1', 41)}},
   {ospf_codec.rhf_ac_tlv, {body=string.rep('1', 42)}},
   {ospf_codec.rhf_ac_tlv, {body=string.rep('1', 43)}},
   {ospf_codec.usp_ac_tlv, {prefix='dead::/16'}},
   {ospf_codec.usp_ac_tlv, {prefix='10.0.0.0/8'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='dead::/16'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='8000::/1'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='::/1'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='::/1'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='1.2.3.0/24'}},
   {ospf_codec.asp_ac_tlv, {iid=3, prefix='dead:feed:dead:feed::/64'}},
   {ospf_codec.json_ac_tlv, {table={foo='bar'}}},
   {ospf_codec.json_ac_tlv, {table={'foo'}}},
   {ospf_codec.json_ac_tlv, {table={'foo'}}},
   {ospf_codec.ddz_ac_tlv, {s=true, address='1.2.3.4', zone={'foo', 'com'}}},
   {ospf_codec.ddz_ac_tlv, {s=true, address='2001::1', zone={'foo', 'com'}}},
   {ospf_codec.ddz_ac_tlv, {b=true, address='2001::1', zone={'foo', 'com'}}},
   {ospf_codec.dn_ac_tlv, {domain={'foo', 'com'}}},
   {ospf_codec.rn_ac_tlv, {name='foo'}},
   {ospf_codec.ds_ac_tlv, {address='1.2.3.4'}},
   {ospf_codec.ds_ac_tlv, {address='2001::1'}},
}

describe("test the ac endecode",
         function ()
            setup(function ()
                     -- make sure the classes do copies of the encoded
                     -- dictionaries, we don't want to copy test vectors
                     -- by hand
                     for i, v in ipairs(tests)
                     do
                        local cl, orig = unpack(v)
                        cl.copy_on_encode = true
                     end
                  end)
            it("basic en-decode ~= same #base", function ()
                  for i, v in ipairs(tests)
                  do
                     local cl, orig = unpack(v)
                     local b = cl:encode(orig)
                     mst.d('handling', orig)
                     mst.d('encode', mst.string_to_hex(b))
                     local o2, err = cl:decode(b)
                     mst.d('decode', o2, err)
                     mst.a(orig)
                     mst.a(o2, 'decode result empty', err)
                     local l2 = ospf_codec.decode_ac_tlvs(b)
                     mst.a(#l2 == 1)
                     local r1 = mst.repr(l2[1])
                     local r2 = mst.repr(o2)
                     mst.a(r1 == r2, 'changed', r1, r2)
                     local r, k = mst.table_contains(o2, orig)
                     mst.a(r, "something missing", cl.class, k, o2, orig)
                  end
                                                end)
            it("can handle list of tlvs", function()
                  -- glom all tests together to one big thing
                  local l = mst.array_map(tests, function (s) 
                                             return s[1]:encode(s[2]) 
                                                 end)
                  local s = table.concat(l)
                  local l2 = ospf_codec.decode_ac_tlvs(s)
                  assert.are.same(#l, #l2)
                                          end)
         end)

describe("make sure stuff is in network order", function ()
            it("works", function ()
                  local r = ospf_codec.json_ac_tlv:encode{table={'foo'}}
                  local _null = string.char(0)
                  local c = string.sub(r, 1, 1)
                  local b = string.byte(c)
                  mst.a(c == _null, 'wierd first character', b)
                  mst.a(string.sub(r, 3, 3) == _null)
                   end)
end)

describe("manually encoded payloads", function ()
            it("test that case with _two_ empty AC TLVs works too (according to draft-ietf-ospf-ospfv3-autoconfig-00, it should be encoded as 0's in TLV) #tlv0", function ()
                  -- type, length (2 bytes ea)
                  local b = mst.hex_to_string('00010000' ..
                                              '00020000')

                  local empty_tlv1 = ospf_codec.ac_tlv:new{class='empty_tlv1', tlv_type=1}
                  local empty_tlv2 = ospf_codec.ac_tlv:new{class='empty_tlv2', tlv_type=2}
                  mst.a(empty_tlv1.header_length == 4)

                  local o, pos = ospf_codec.decode_ac_tlvs(b, {empty_tlv1, empty_tlv2})
                  mst.a(o, 'decode error')
                  mst.a(#o == 2, 'incorrect # of results', o, pos, #b)
                  mst.a(o[1].type == 1, 'wrong type 1')
                  mst.a(o[2].type == 2, 'wrong type 2')
                  -- should be able to encode to same result too
                  local b2 = 
                     empty_tlv1:do_encode(o[1]) ..
                     empty_tlv2:do_encode(o[2]) 
                  mst.a(b == b2, 'encode mismatch')
                   end)
            it("test en-decode with manually encoded IPv6 ASP #asp", function ()
                  mst.a(ospf_codec.asp_ac_tlv.header_length == 8)
                  local b = mst.hex_to_string(
                     '0003' .. -- ASP
                        '0010' .. -- 16 bytes (4 iid, 1+3 len, 8 prefix)

                        '0000002a' .. -- 4 bytes, iid, 42

                        -- 4 bytes
                        '40' .. -- prefix length (in bits)
                        '000000' .. -- reserved'
                        
                        'deadbeefcafef00d' -- 8 bytes of prefix'
                   )
                  mst.a(#b == 4 + 16) -- base header + what we put in TLV
                  local o, pos = ospf_codec.decode_ac_tlvs(b)
                  mst.a(pos == #b)
                  mst.a(o)
                  mst.a(#o == 1)
                  mst.d('got', o)
                  local b2 = 
                     ospf_codec.asp_ac_tlv:encode(o[1])
                  mst.a(b == b2, 'encode mismatch')

                                                                end)

end)
