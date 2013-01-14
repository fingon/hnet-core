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
-- Last modified: Mon Jan 14 13:04:20 2013 mstenber
-- Edit time:     2 min
--

-- these aren't intentionally within own namespace - the MDNS_ should
-- be obvious enough indication of the globally shared nature.
--module(...)

MDNS_MULTICAST_ADDRESS='ff02::fb'
MDNS_PORT=5353
MDNS_DEFAULT_RESPONSE_HEADER={qr=true, aa=true}

