#!/bin/bash -e
#-*-sh-*-
#
# $Id: run_hp.sh $
#
# Author: Markus Stenberg <fingon@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Thu Sep 27 12:51:34 2012 mstenber
# Last modified: Thu Jun 20 17:48:48 2013 mstenber
# Edit time:     6 min
#

# Propagate LUA_PATH so that required modules can be found more easily..

if [ "$1" = "-d" ]
then
    shift
    sudo ENABLE_MST_DEBUG=1 LUA_PATH=$LUA_PATH ./hp.lua $* 2>&1 | tee ~/hp.log
else
    sudo LUA_PATH=$LUA_PATH ./hp.lua $*
fi
