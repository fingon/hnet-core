#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: dhcpv6_const.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Wed Feb 20 18:14:36 2013 mstenber
-- Last modified: Mon Feb 25 14:37:28 2013 mstenber
-- Edit time:     16 min
--

module(...)

-- RFC3315 stuff
CLIENT_PORT = 546
SERVER_PORT = 547
ALL_RELAY_AGENTS_AND_SERVERS_ADDRESS = 'ff02::1:2'

-- message types
MT_SOLICIT               = 1
MT_ADVERTISE             = 2
MT_REQUEST               = 3
MT_CONFIRM               = 4
MT_RENEW                 = 5
MT_REBIND                = 6
MT_REPLY                 = 7
MT_RELEASE               = 8
MT_DECLINE               = 9
MT_RECONFIGURE           = 10
MT_INFORMATION_REQUEST   = 11
MT_RELAY_FORW            = 12
MT_RELAY_REPL            = 13

-- options
O_CLIENTID       = 1
O_SERVERID       = 2
O_IA_NA          = 3
O_IA_TA          = 4
O_IAADDR         = 5
O_ORO            = 6
O_PREFERENCE     = 7
O_ELAPSED_TIME   = 8
O_RELAY_MSG      = 9
O_AUTH           = 11
O_UNICAST        = 12
O_STATUS_CODE    = 13
O_RAPID_COMMIT   = 14
O_USER_CLASS     = 15
O_VENDOR_CLASS   = 16
O_VENDOR_OPTS    = 17
O_INTERFACE_ID   = 18
O_RECONF_MSG     = 19
O_RECONF_ACCEPT  = 20
O_DNS_RNS        = 23 -- RFC3646 
O_DOMAIN_SEARCH  = 24 -- RFC3646 
O_IA_PD          = 25 -- RFC3633
O_IAPREFIX       = 26 -- RFC3633

O_PREFIX_CLASS   = 200 -- draft-bhandari-dhc-class-based-prefix-04

-- status codes
S_SUCCESS         = 0
S_UNSPEC_FAIL     = 1
S_NOADDRS_AVAIL   = 2
S_NO_BINDING      = 3
S_NOT_ON_LINK     = 4
S_USE_MULTICAST   = 5
S_NO_PREFIX_AVAIL = 6 -- RFC3633

-- DUID types
DUID_LLT                       = 1
DUID_EN                        = 2
DUID_LL                        = 3


