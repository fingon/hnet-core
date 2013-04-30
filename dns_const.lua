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
-- Last modified: Tue Apr 30 16:39:40 2013 mstenber
-- Edit time:     0 min
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


