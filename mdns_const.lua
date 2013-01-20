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
-- Last modified: Sun Jan 20 10:21:46 2013 mstenber
-- Edit time:     2 min
--

module(...)

MULTICAST_ADDRESS='ff02::fb'
PORT=5353
DEFAULT_RESPONSE_HEADER={qr=true, aa=true}
DEFAULT_NONAME_TTL=(60 * 75)
DEFAULT_NAME_TTL=120


