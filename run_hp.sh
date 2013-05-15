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
# Last modified: Wed May 15 15:32:24 2013 mstenber
# Edit time:     5 min
#

# Propagate LUA_PATH so that required modules can be found more easily..

if [ "$1" = "-d" ]
then
    shift
    sudo ENABLE_MST_DEBUG=1 LUA_PATH=$LUA_PATH ./hp.lua $*
else
    sudo LUA_PATH=$LUA_PATH ./hp.lua $*
fi
