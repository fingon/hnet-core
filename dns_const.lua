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
-- Last modified: Mon May 13 15:38:58 2013 mstenber
-- Edit time:     3 min
--

module(...)

-- protocol port #
PORT=53

CLASS_IN=1
CLASS_ANY=255

-- RFC1035
TYPE_A=1
TYPE_NS=2
TYPE_CNAME=5
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
RCODE_FORMAT_ERROR=1 -- name server unable to understand query
RCODE_SERVER_FAILURE=2 -- name server unable to process due to problem with server
RCODE_NAME_ERROR=3 -- name does not exist (meaningful only from authoritative)
RCODE_NOT_IMPLEMENTED=4 -- name server does not support requested kind of query
RCODE_REFUSED=5 -- name server won't honor this query for some reason

-- reverse LL for IPv4
REVERSE_LL_IPV4={'in-addr', 'arpa'}

-- reverse LL for IPv6
REVERSE_LL_IPV6={'ip6', 'arpa'}
