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
# Last modified: Mon Dec  3 14:21:39 2012 mstenber
# Edit time:     13 min
#

# Run lua for 'require X, check memory stats' for various things, and
# print results (suitable for e.g. sort -n)

INTERESTING_MODULES="
io 
string

cliargs
md5
socket
statemap 
vstruct

codec
elsa_pa
ipv6s
mst
pa
pa_lap_sm 
pm_core
scb
skv
skv_sm 
"

for MODULE in $INTERESTING_MODULES
do
    lua -e "require '$MODULE';collectgarbage();print(math.floor(collectgarbage('count')),'$MODULE')"
    # Test double require isn't broken - it isn't, though => same #
    #lua -e "local m1=require '$MODULE';local m2=require '$MODULE';collectgarbage();print(math.floor(collectgarbage('count')),'$MODULE x2')"
done
