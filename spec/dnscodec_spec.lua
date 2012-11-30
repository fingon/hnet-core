#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dnscodec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 30 12:06:56 2012 mstenber
-- Last modified: Fri Nov 30 14:19:37 2012 mstenber
-- Edit time:     23 min
--

require "busted"
require "dnscodec"

module("dnscodec_spec", package.seeall)

local dns_rr = dnscodec.dns_rr
local dns_query = dnscodec.dns_query
local dns_message = dnscodec.dns_message

local tests = {
   -- minimal
   {dns_rr, {name={}, rtype=1, rdata=''}},
   {dns_rr, {name={'foo', 'bar'}, rtype=2, rclass=3, ttl=4, rdata='baz'}},
   {dns_query, {name={}}},
   {dns_query, {name={}, qtype=255, qclass=42}},
}

local message_tests = {
   {qd={{name={'foo'}, rdata=''},}},
   {an={{name={'foo'}, rdata=''},}},
   {ns={{name={'foo'}, rdata=''},}},
   {ar={{name={'foo'}, rdata=''},}},
}

local known_messages = {
{'000084000000000400000009046d696e690c5f6465766963652d696e666f045f746370056c6f63616c0000100001000011940011106d6f64656c3d4d61636d696e69332c310b5f6166706f766572746370c01e000c0001000011940007046d696e69c045045f697070c01e000c00010000119400211e53616d73756e67205343582d34353030205365726965732040206d696e69c064c064000c00010000119400181553656e6420746f204b696e646c652040206d696e69c064c05d0010800100001194000100c05d0021800100000078000d000000000224046d696e69c023c075001080010000119401a409747874766572733d310871746f74616c3d312372703d7072696e746572732f53616d73756e675f5343585f343530305f5365726965731a74793d53616d73756e67205343582d34353030205365726965734161646d696e75726c3d68747470733a2f2f6d696e692e6c6f63616c2e3a3633312f7072696e746572732f53616d73756e675f5343585f343530305f536572696573186e6f74653d4d61726b7573e2809973204d6163206d696e690a7072696f726974793d302170726f647563743d2853616d73756e67205343582d3435303020536572696573296970646c3d6170706c69636174696f6e2f6f637465742d73747265616d2c6170706c69636174696f6e2f7064662c6170706c69636174696f6e2f706f73747363726970742c696d6167652f6a7065672c696d6167652f706e672c696d6167652f7077672d72617374657229555549443d62646663616531382d386139382d336337342d366439372d30623865636337376230313307544c533d312e32065363616e3d540f7072696e7465722d73746174653d33167072696e7465722d747970653d307834303039303036c0a20010800100001194017a09747874766572733d310871746f74616c3d311672703d7072696e746572732f73746b5072696e7465722d74793d416d617a6f6e2e636f6d2c20496e632e2053656e6420746f204b696e646c652c20312e302e302e3231343461646d696e75726c3d68747470733a2f2f6d696e692e6c6f63616c2e3a3633312f7072696e746572732f73746b5072696e7465720a7072696f726974793d301870726f647563743d2853656e6420746f204b696e646c65296970646c3d6170706c69636174696f6e2f6f637465742d73747265616d2c6170706c69636174696f6e2f7064662c6170706c69636174696f6e2f706f73747363726970742c696d6167652f6a7065672c696d6167652f706e672c696d6167652f7077672d72617374657229555549443d30383963653939632d363133392d333763612d373932332d64663737633738666332343107544c533d312e3208436f706965733d540f7072696e7465722d73746174653d33137072696e7465722d747970653d307831303436c07500218001000000780008000000000277c0d9c0a200218001000000780008000000000277c0d9c05d002f8001000011940009c05d00050000800040c075002f8001000011940009c07500050000800040c0a2002f8001000011940009c0a200050000800040', 
 {qd=0, an=4, ns=0, ar=9},
},
}

local message_lists = {'qd', 'an', 'ns', 'ar'}

describe("test dnscodec", function ()
            it("encode + decode =~ same", function ()
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
                     mst.a(mst.table_contains(o2, orig), "something missing", cl.class, o2, orig)

                  end
                                          end)
            it("dns_message endecode =~ same", function ()
                  local cl = dns_message
                  for i, orig in ipairs(message_tests)
                  do
                     local b = cl:encode(orig)
                     mst.d('handling', orig)
                     mst.d('encode', mst.string_to_hex(b))
                     local o2, err = cl:decode(b)
                     mst.d('decode', o2, err)
                     mst.a(orig)
                     mst.a(o2, 'decode result empty', err)
                     mst.a(o2.h, 'no header?', o2.h)
                     -- make sure header stays same
                     mst.a(mst.table_contains(o2.h, orig.h or {}),
                           'something missing from header')
                     --mst.d('handling2', orig)
                     for i, np in ipairs(message_lists)
                     do
                        local l2 = o2[np] or {}
                        local l1 = orig[np] or {}
                        mst.a(#l1 == #l2, 'list mismatch', np)
                        mst.d(' ok count', np, #l1, l1)
                     end

                  end
                                               end)

            it("sanity checks", function ()
                  mst.a(dnscodec.dns_header.header_length == 12,
                       'wrong header length')
                   end)
            it("test actual message decoding #real", function ()
                  for i, v in ipairs(known_messages)
                  do
                     local h, cnts = unpack(v)
                     local s = mst.hex_to_string(h)
                     local o, err = dns_message:decode(s)
                     mst.a(o, 'decode error', err)
                     for k, v in pairs(cnts)
                     do
                        mst.a(#o[k] == v, 'count mismatch', np)
                     end
                  end
                   end)
end)
