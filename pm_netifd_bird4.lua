#!/usr/bin/env lua
-- -*-lua-*-
--
-- $Id: pm_netifd_bird4.lua $
--
-- Author: Markus Stenberg <markus stenberg@iki.fi>
--
-- Copyright (c) 2013 cisco Systems, Inc.
--
-- Created:       Thu Oct 10 13:58:16 2013 mstenber
-- Last modified: Thu Oct 10 14:07:21 2013 mstenber
-- Edit time:     2 min
--

-- as we have strict module = handler mapping, we provide here bird6
-- subclass which just changes the script..

require 'pm_handler'
require 'pm_netifd_bird6'

module(..., package.seeall)

BIRD4_SCRIPT='/usr/share/hnet/bird4_handler.sh'

local _parent = pm_netifd_bird6.pm_netifd_bird6

pm_netifd_bird4 = _parent:new_subclass{class='pm_netifd_bird4',
                                       script=BIRD4_SCRIPT}
