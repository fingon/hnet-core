#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dns_const.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Mon Jan 14 13:03:28 2013 mstenber
-- Last modified: Mon May 20 13:04:57 2013 mstenber
-- Edit time:     9 min
--

module(...)

-- based on http://www.iana.org/assignments/dns-parameters/dns-parameters.xml

-- protocol port #
PORT=53

CLASS_IN=1
CLASS_ANY=255

-- RFC1035
TYPE_A=1
TYPE_NS=2
TYPE_CNAME=5
TYPE_SOA=6
TYPE_PTR=12
TYPE_HINFO=13
TYPE_MX=15
TYPE_TXT=16

-- RFC3596
TYPE_AAAA=28

-- RFC2782
TYPE_SRV=33

-- RFC4304
TYPE_RRSIG=46
TYPE_NSEC=47
TYPE_DNSKEY=48


TYPE_ANY=255


-- RFC1035
RCODE_NOERR=0
RCODE_FORMERR=1 -- name server unable to understand query
RCODE_SERVFAIL=2 -- name server unable to process due to problem with server
RCODE_NXDOMAIN=3 -- name does not exist (meaningful only from authoritative)
RCODE_NOTIMP=4 -- name server does not support requested kind of query
RCODE_REFUSED=5 -- name server won't honor this query for some reason

-- RFC1035
OPCODE_QUERY=0
OPCODE_IQUERY=1 -- obsolete as of RFC3425
OPCODE_STATUS=2

OPCODE_NOTIFY=4 -- RFC1996
OPCODE_UPDATE=4 -- RFC2136

-- reverse LL for IPv4
REVERSE_LL_IPV4={'in-addr', 'arpa'}

-- reverse LL for IPv6
REVERSE_LL_IPV6={'ip6', 'arpa'}

GOOGLE_IPV4='8.8.8.8'
GOOGLE_IPV6='2001:4860:4860::8888'

B_DNS_SD_LL={'b', '_dns-sd', '_udp'}
