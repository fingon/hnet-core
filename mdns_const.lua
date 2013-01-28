#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: mdns_const.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Jan 10 14:59:37 2013 mstenber
-- Last modified: Mon Jan 28 15:19:52 2013 mstenber
-- Edit time:     2 min
--

module(...)

MULTICAST_ADDRESS_IPV4='224.0.0.251'
MULTICAST_ADDRESS_IPV6='ff02::fb'
PORT=5353
DEFAULT_RESPONSE_HEADER={qr=true, aa=true}
DEFAULT_NONAME_TTL=(60 * 75)
DEFAULT_NAME_TTL=120


