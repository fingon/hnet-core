#!/bin/bash -ue
#-*-sh-*-
#
# $Id: run_lua_memory_stats.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Tue Nov 27 14:21:37 2012 mstenber
# Last modified: Tue Nov 27 14:55:22 2012 mstenber
# Edit time:     10 min
#

# Run lua for 'require X, check memory stats' for various things, and
# print results (suitable for e.g. sort -n)

INTERESTING_MODULES="string mst scb cliargs pa skv elsa_pa pm_core vstruct md5 ipv6s pa_lap_sm statemap skv_sm io codec"

for MODULE in $INTERESTING_MODULES
do
    lua -e "require '$MODULE';collectgarbage();print(math.floor(collectgarbage('count')),'$MODULE')"
    # Test double require isn't broken - it isn't, though => same #
    #lua -e "local m1=require '$MODULE';local m2=require '$MODULE';collectgarbage();print(math.floor(collectgarbage('count')),'$MODULE x2')"
done
