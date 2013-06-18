#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_codec_spec.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2012 cisco Systems, Inc.
--
-- Created:       Fri Nov 30 12:06:56 2012 mstenber
-- Last modified: Tue Jun 18 17:38:19 2013 mstenber
-- Edit time:     120 min
--

require "busted"
require "dns_codec"
require 'dns_const'
require 'dns_rdata'
require 'mst_test'

local json = require "dkjson"

module("dns_codec_spec", package.seeall)

local dns_rr = dns_codec.dns_rr
local dns_query = dns_codec.dns_query
local dns_message = dns_codec.dns_message
local rdata_srv = dns_rdata.rdata_srv
local rdata_nsec = dns_rdata.rdata_nsec

local json_tests = {'[{"rclass":1440,"rtype":41,"name":[],"rdata":"\u0000\u0004\u0000\u000e\u0000\u0000??&\u0004\u0004?@l?B??"},{"rclass":1440,"rtype":41,"name":[],"rdata":"\u0000\u0004\u0000\b\u0000\u001b???\u0016??"},{"name":["mini","_afpovertcp","_tcp","local"],"rdata":"\u0000","rclass":1,"rtype":16,"cache_flush":true},{"rclass":1,"rtype":16,"name":["_kerberos","suiren","local"],"rdata":"2LKDC:SHA1.85C8F3B0244B89CE3953343AF04EC1635BC97E8C"},{"rclass":1,"rtype":16,"name":["suiren","_device-info","_tcp","local"],"rdata":"\u0013model=MacBookAir5,2"},{"name":["Samsung SCX-4500 Series @ mini","_ipps","_tcp","local"],"rdata":"\ttxtvers=1\bqtotal=1#rp=printers/Samsung_SCX_4500_Series\u001aty=Samsung SCX-4500 SeriesAadminurl=https://mini.local.:631/printers/Samsung_SCX_4500_Series\u0018note=Markus’s Mac mini\npriority=0!product=(Samsung SCX-4500 Series)ipdl=application/octet-stream,application/pdf,application/postscript,image/jpeg,image/png,image/pwg-raster)UUID=bdfcae18-8a98-3c74-6d97-0b8ecc77b013\u0007TLS=1.2\u0006Scan=T\u000fprinter-state=3\u0016printer-type=0x4009006","rclass":1,"rtype":16,"cache_flush":true},{"name":["65","94","239","10","in-addr","arpa"],"rdata_ptr":["suiren","local"],"rclass":1,"rtype":12,"cache_flush":true},{"name":["9","D","E","A","2","4","E","F","F","F","F","8","C","6","2","4","0","0","0","0","0","0","0","0","0","0","0","0","0","8","E","F","ip6","arpa"],"rdata_ptr":["suiren","local"],"rclass":1,"rtype":12,"cache_flush":true},{"name":["9","D","E","A","2","4","E","F","F","F","F","8","C","6","2","4","B","7","3","9","E","5","D","D","0","7","4","0","1","0","0","2","ip6","arpa"],"rdata_ptr":["suiren","local"],"rclass":1,"rtype":12,"cache_flush":true},{"name":["suiren","local"],"rdata_aaaa":"2001:470:dd5e:937b:426c:8fff:fe42:aed9","rclass":1,"rtype":28,"cache_flush":true},{"name":["suiren","local"],"rdata_a":"10.239.94.65","rclass":1,"rtype":1,"cache_flush":true},{"name":["suiren","_sftp-ssh","_tcp","local"],"rdata":"\u0000","rclass":1,"rtype":16,"cache_flush":true},{"rclass":1,"rtype":12,"name":["_sftp-ssh","_tcp","local"],"rdata_ptr":["suiren","_sftp-ssh","_tcp","local"]},{"rdata_srv":{"target":["suiren","local"],"priority":0,"port":22,"weight":0},"name":["suiren","_sftp-ssh","_tcp","local"],"rclass":1,"rtype":33,"cache_flush":true},{"name":["Samsung SCX-4500 Series @ mini","_ipp","_tcp","local"],"rdata":"\ttxtvers=1\bqtotal=1#rp=printers/Samsung_SCX_4500_Series\u001aty=Samsung SCX-4500 SeriesAadminurl=https://mini.local.:631/printers/Samsung_SCX_4500_Series\u0018note=Markus’s Mac mini\npriority=0!product=(Samsung SCX-4500 Series)ipdl=application/octet-stream,application/pdf,application/postscript,image/jpeg,image/png,image/pwg-raster)UUID=bdfcae18-8a98-3c74-6d97-0b8ecc77b013\u0007TLS=1.2\u0006Scan=T\u000fprinter-state=3\u0016printer-type=0x4009006","rclass":1,"rtype":16,"cache_flush":true},{"rclass":1,"rtype":12,"name":["_services","_dns-sd","_udp","local"],"rdata_ptr":["_sftp-ssh","_tcp","local"]},{"name":["suiren","_rfb","_tcp","local"],"rdata":"\u0000","rclass":1,"rtype":16,"cache_flush":true},{"rclass":1,"rtype":12,"name":["_services","_dns-sd","_udp","local"],"rdata_ptr":["_rfb","_tcp","local"]},{"rclass":1,"rtype":12,"name":["_rfb","_tcp","local"],"rdata_ptr":["suiren","_rfb","_tcp","local"]},{"rdata_srv":{"target":["suiren","local"],"priority":0,"port":5900,"weight":0},"name":["suiren","_rfb","_tcp","local"],"rclass":1,"rtype":33,"cache_flush":true},{"name":["suiren","_ssh","_tcp","local"],"rdata":"\u0000","rclass":1,"rtype":16,"cache_flush":true},{"rclass":1,"rtype":12,"name":["_services","_dns-sd","_udp","local"],"rdata_ptr":["_ssh","_tcp","local"]},{"rclass":1,"rtype":12,"name":["_ssh","_tcp","local"],"rdata_ptr":["suiren","_ssh","_tcp","local"]},{"rdata_srv":{"target":["suiren","local"],"priority":0,"port":22,"weight":0},"name":["suiren","_ssh","_tcp","local"],"rclass":1,"rtype":33,"cache_flush":true}]'}


local tests = {
   -- minimal
   {dns_rr, {name={}, rtype=42, rdata=''}},
   {dns_rr, {name={}, rtype=42, cache_flush=true, rdata=''}},
   {dns_rr, {name={'foo', 'bar'}, rtype=123, rclass=3, ttl=4, rdata='baz'}},
   {dns_query, {name={'z'}}},
   {dns_query, {name={'z'}, qu=true}},
   {dns_query, {name={'y'}, qtype=255, qclass=42}},
   {rdata_srv, {priority=123, weight=42, port=234, target={'foo', 'bar'}}},
   {dns_rr, {name={}, rtype=dns_const.TYPE_A, rdata_a='1.2.3.4'}},
   {dns_rr, {name={}, rtype=dns_const.TYPE_PTR, rdata_ptr={'foo', 'bar'}}},
   {dns_rr, {name={}, rtype=dns_const.TYPE_NS, rdata_ns={'foo', 'bar'}}},
   {dns_rr, {name={}, rtype=dns_const.TYPE_AAAA, rdata_aaaa='f80:dead:beef::'}},
}

-- start with readably(?) encoded data, decode it, compare it to
-- expected result, encode it, and hope encoded result matches what we
-- want again
local encoded_tests = {
   {rdata_srv,
    {0, 1, 0, 2, 0, 3,
     0x04,'h','o','s','t',
     0x07,'e','x','a','m','p','l','e',
     0x03,'c','o','m',0x00},
    {priority=1, weight=2, port=3, target={'host', 'example', 'com'}}},
  {rdata_nsec, 
    {0x04,'h','o','s','t',
     0x07,'e','x','a','m','p','l','e',
     0x03,'c','o','m',0x00,
     0x00,0x06,0x40,0x01,0x00,0x00,0x00,0x03,
     0x04,0x1b,0x00,0x00,0x00,0x00,0x00,0x00,
     0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
     0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
     0x00,0x00,0x00,0x00,0x20},
    {ndn={'host','example','com'},
     bits={dns_const.TYPE_A, dns_const.TYPE_MX,
           dns_const.TYPE_RRSIG, dns_const.TYPE_NSEC,
           1234},
    }
   },
}



local message_tests = {
   {qd={{name={'foo'}, rdata=''},}},
   {an={{name={'foo'}, rdata=''},}},
   {ns={{name={'foo'}, rdata=''},}},
   {ar={{name={'foo'}, rdata=''},}},
}

local LONG_LABEL={'1234567890123456789012345678901234567890123456789012345678901234'}

local LONG_NAME={'123456789012345678901234567890123456789012345678901234567890',
                 '123456789012345678901234567890123456789012345678901234567890',
                 '123456789012345678901234567890123456789012345678901234567890',
                 '123456789012345678901234567890123456789012345678901234567890',
                 '123456789012345678901234567890123456789012345678901234567890',
}

local failing_encode_cases = {
   -- query name (1, 2)
   {qd={{name=LONG_LABEL}}},
   {qd={{name=LONG_NAME}}},

   -- for the rest, we ju st try the LONG_NAME; we use same encoder
   -- anyway

   -- rr name (3)
   {an={{name=LONG_NAME}}},

   -- ptr/ns/rname ll field handling are all the same (4)
   {an={{name={'foo'},
         rtype=dns_const.TYPE_PTR,
         rclass=dns_const.CLASS_IN,
         rdata_ptr=LONG_NAME}}},
   -- SRV has target (5)
   {an={{name={'foo'},
         rtype=dns_const.TYPE_SRV,
         rclass=dns_const.CLASS_IN,
         rdata_srv={target=LONG_NAME}}}},
   -- SOA has mname, rname (6, 7)
   {an={{name={'foo'},
         rtype=dns_const.TYPE_SOA,
         rclass=dns_const.CLASS_IN,
         rdata_soa={mname=LONG_NAME,
                    rname={'foo'}}}}},
   {an={{name={'foo'},
         rtype=dns_const.TYPE_SOA,
         rclass=dns_const.CLASS_IN,
         rdata_soa={mname={'foo'},
                    rname=LONG_NAME}}}},
   -- NSEC has ndn (8)
   {an={{name={'foo'},
         rtype=dns_const.TYPE_NSEC,
         rclass=dns_const.CLASS_IN,
         rdata_nsec={ndn=LONG_NAME}}}},


}

local partial_messages = {
   -- fake, incorrect message :-)
   -- message + decode context + expected value with context (w/o = nil)

   --format='id:u2 [2|qr:b1 opcode:u4 aa:b1 tc:b1 rd:b1 ra:b1 z:u1 ad:b1 cd:b1 rcode:u4] qdcount:u2 ancount:u2 nscount:u2 arcount:u2',

   {'0001' .. -- id 
      '0000' .. -- flags
      '0001' .. -- qdcount
      '0000' .. -- ancount
      '0000' .. -- nscount
      '0000' .. -- arcount
      -- query
      'ffff' .. -- fake name compression entry that is broken
      '0001' .. -- qtype
      '0001', -- qclass
      {disable_decode_names=true}
   },

   {'0001' .. -- id 
      '0000' .. -- flags
      '0000' .. -- qdcount
      '0001' .. -- ancount
      '0000' .. -- nscount
      '0000' .. -- arcount
      -- rr
      'ffff' .. -- fake name compression entry that is broken
      '0001' .. -- rtype
      '0001' .. -- rclass
      '00000000' .. -- ttl
      '0001' .. -- rdlength
      '01',
      {disable_decode_names=true,
       disable_decode_rrs =true}
   },
}

local known_messages = {
-- query example
   {'000000000002000000020000013201300163016601380133016501660166016601380165013401310138016401630139016501320130016501650162016401610165016401300130013001320369703604617270610000ff000107636c69656e7433056c6f63616c0000ff0001c05a001c00010000007800102000deadbee02e9cd814e8fffe38fc02c00c000c0001000000780002c05a', {qd=2}
   },
-- example with PTR's 
{'000084000000000400000009046d696e690c5f6465766963652d696e666f045f746370056c6f63616c0000100001000011940011106d6f64656c3d4d61636d696e69332c310b5f6166706f766572746370c01e000c0001000011940007046d696e69c045045f697070c01e000c00010000119400211e53616d73756e67205343582d34353030205365726965732040206d696e69c064c064000c00010000119400181553656e6420746f204b696e646c652040206d696e69c064c05d0010800100001194000100c05d0021800100000078000d000000000224046d696e69c023c075001080010000119401a409747874766572733d310871746f74616c3d312372703d7072696e746572732f53616d73756e675f5343585f343530305f5365726965731a74793d53616d73756e67205343582d34353030205365726965734161646d696e75726c3d68747470733a2f2f6d696e692e6c6f63616c2e3a3633312f7072696e746572732f53616d73756e675f5343585f343530305f536572696573186e6f74653d4d61726b7573e2809973204d6163206d696e690a7072696f726974793d302170726f647563743d2853616d73756e67205343582d3435303020536572696573296970646c3d6170706c69636174696f6e2f6f637465742d73747265616d2c6170706c69636174696f6e2f7064662c6170706c69636174696f6e2f706f73747363726970742c696d6167652f6a7065672c696d6167652f706e672c696d6167652f7077672d72617374657229555549443d62646663616531382d386139382d336337342d366439372d30623865636337376230313307544c533d312e32065363616e3d540f7072696e7465722d73746174653d33167072696e7465722d747970653d307834303039303036c0a20010800100001194017a09747874766572733d310871746f74616c3d311672703d7072696e746572732f73746b5072696e7465722d74793d416d617a6f6e2e636f6d2c20496e632e2053656e6420746f204b696e646c652c20312e302e302e3231343461646d696e75726c3d68747470733a2f2f6d696e692e6c6f63616c2e3a3633312f7072696e746572732f73746b5072696e7465720a7072696f726974793d301870726f647563743d2853656e6420746f204b696e646c65296970646c3d6170706c69636174696f6e2f6f637465742d73747265616d2c6170706c69636174696f6e2f7064662c6170706c69636174696f6e2f706f73747363726970742c696d6167652f6a7065672c696d6167652f706e672c696d6167652f7077672d72617374657229555549443d30383963653939632d363133392d333763612d373932332d64663737633738666332343107544c533d312e3208436f706965733d540f7072696e7465722d73746174653d33137072696e7465722d747970653d307831303436c07500218001000000780008000000000277c0d9c0a200218001000000780008000000000277c0d9c05d002f8001000011940009c05d00050000800040c075002f8001000011940009c07500050000800040c0a2002f8001000011940009c0a200050000800040', 
 {qd=0, an=4, ns=0, ar=9},
},
-- example with SRV/A/AAAA records
{'000084000000000100000006' ..
'045f726662045f746370056c6f63616c00000c0001000011940007046d696e69c00cc0270021800100000078000d00000000170c046d696e69c016c0270010800100001194000100046d696e690c5f6465766963652d696e666fc01100100001000011940011106d6f64656c3d4d61636d696e69332c31c040001c8001000000780010fe80000000000000d69a20fffefd7b50c04000018001000000780004c0a82a03c040001c800100000078001020010470dd5e0000d69a20fffefd7b50', {an=1, ar=6}},

-- example with CNAME + 9x A
{'9ed4818000010009000000000a33322d636f75726965720470757368056170706c6503636f6d0000010001c00c0005000100005457002602333212636f75726965722d707573682d6170706c6503636f6d06616b61646e73036e657400c03700010001000000330004119524e3c0370001000100000033000411952479c03700010001000000330004119524e2c0370001000100000033000411952026c037000100010000003300041195247ac037000100010000003300041195203bc0370001000100000033000411952044c03700010001000000330004119524d4', {qd=1, an=9}},

-- example with q + CNAME + SOA
{'7775818000010001000100000a33322d636f75726965720470757368056170706c6503636f6d00001c0001c00c00050001000053bc002602333212636f75726965722d707573682d6170706c6503636f6d06616b61646e73036e657400c0510006000100000010003308696e7465726e616cc0510a686f73746d617374657206616b616d6169c0225199eee400015f9000015f9000015f90000000b4', {qd=1, an=1, ns=1}},
}

local message_lists = {'qd', 'an', 'ns', 'ar'}

describe("test dns_codec", function ()
            it("encode + decode =~ same", function ()
                  for i, v in ipairs(tests)
                  do
                     local cl, orig = unpack(v)
                     local b = cl:encode(mst.table_copy(orig))
                     mst.d('handling', orig)
                     mst.d('encode', mst.string_to_hex(b))
                     local o2, err = cl:decode(b)
                     mst.d('decode', o2, err)
                     mst.a(orig)
                     mst.a(o2, 'decode result empty', err)
                     for k, v in pairs(orig)
                     do
                        mst.a(mst.repr_equal(o2[k], v),
                              'mismatch key', k, v, o2[k])
                     end
                  end
                                          end)
            it("decode + encode =~ same #de", function ()
                  for i, v in ipairs(encoded_tests)
                  do
                     local cl, orig_readable, r = unpack(v)
                     local orig
                     mst.d('item', i, #orig_readable)
                     if type(orig_readable) == 'table'
                     then
                        -- convert the table to string
                        local a = 
                           mst.array_map(orig_readable, 
                                         function (c)
                                            if type(c) == 'number'
                                            then
                                               c = string.char(c)
                                            end
                                            return c
                                         end)
                           orig = table.concat(a)
                     else
                        mst.a(type(orig_readable) == 'string')
                        orig = orig_readable
                     end
                     mst.d('got binary', #orig)
                     local o, err = cl:decode(orig)
                     mst.a(o, 'decode failure', err)
                     mst.d('decoded ok', o)
                     mst.a(mst.table_contains(o, r), "something missing", cl.class, o, r)
                     local b, err = cl:encode(o)
                     mst.a(b, 'encode failure', err)
                     mst.d('encoded ok', #b)
                     mst.d('was', mst.string_to_hex(orig))
                     mst.d('got', mst.string_to_hex(b))
                     mst.a(b == orig, 'binary mismatch')
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
                  mst.a(dns_codec.dns_header.header_length == 12,
                       'wrong header length')
                   end)

            it("test actual message decoding #real", function ()
                  for i, v in ipairs(known_messages)
                  do
                     mst.d('case', i)
                     local h, cnts = unpack(v)
                     h = string.gsub(h, "\n", "")
                     local s = mst.hex_to_string(h)
                     local o, err = dns_message:decode(s)
                     mst.a(o, 'decode error', err)
                     for k, v in pairs(cnts)
                     do
                        mst.a(#o[k] == v, 'count mismatch', k)
                        for i, rr in ipairs(o[k])
                        do
                           if rr.rclass
                           then
                              mst.a(rr.rclass == dns_const.CLASS_IN,
                                   'wierd class', rr)
                           end
                           if rr.qclass
                           then
                              mst.a(rr.qclass == dns_const.CLASS_IN,
                                   'wierd class', rr)
                           end
                        end
                     end
                     -- make sure we can encode it too
                     mst.d('trying to encode', o)
                     local s2 = dns_message:encode(o)

                     -- s18.27 SHOULD use name compression
                     -- (yes, we do, Apple does it, we decode it ok,
                     -- and encode to same)

                     -- and the result should be same length
                     --mst.a(#s == #s2, 'decode->encode, different length', #s, #s2)

                     -- and same content

                     -- due to ordering, can't be same.. but should be
                     -- decode+encodable to yet another one with same
                     -- length
                     mst.a(s == s2, 'decode->encode, different content')
                     local o2, err = dns_message:decode(s2)
                     mst.a(o2, 'decode error', err)
                     local s3 = dns_message:encode(o2)

                     -- now we can be sure that as we encoded both,
                     -- result should be same
                     mst.a(s2 == s3)


                  end
                   end)
            it("can also deal with cruft from json captures", function ()
                  for i, s in ipairs(json_tests)
                  do
                     local a = json.decode(s)
                     mst.a(a)
                     local b = dns_message:encode{an=a}
                     mst.a(b)
                     mst.d('original json string', #s)
                     mst.d('encoded in dns_message', #b)

                  end
                   end)
            it("dns_message partial decode works #partial", function ()
                  for i, v in ipairs(partial_messages)
                  do
                     local h, opt, exp = unpack(v)
                     local s = mst.hex_to_string(h)
                     local o, err = dns_message:decode(s)
                     mst.a(not o, 'no decode error', o, err)
                     local o, err = dns_message:decode(s, opt)
                     mst.a(o, 'decode error', err)
                     -- exp data is boring and not worth it :p
                     --mst.a(mst.repr_equal(o, exp), 'not same', o, exp)
                  end
                   end)
            it("failing RFC1035 cases (try to cover most branches) #size", function ()
                  local function try_message_encode(o)
                     local b = dns_message:encode(o)
                     return b
                  end
                  failing_encode_cases = mst.array_map(failing_encode_cases,
                                                       function (o)
                                                          return {o, nil}
                                                       end)
                  mst_test.test_list(failing_encode_cases, try_message_encode)
                   end)
end)
