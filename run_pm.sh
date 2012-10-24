#!/bin/bash -e
#-*-sh-*-
#
# $Id: run_elsa.sh $
#
# Author: Markus Stenberg <fingon@iki.fi>
#
#  Copyright (c) 2012 cisco Systems, Inc.
#       All rights reserved
#
# Created:       Thu Sep 27 12:51:34 2012 mstenber
# Last modified: Fri Oct  5 01:27:27 2012 mstenber
# Edit time:     4 min
#

# Propagate LUA_PATH so that required modules can be found more easily..

if [ $# = 1 -a "$1" = "-d" ]
then
    sudo ENABLE_MST_DEBUG=1 LUA_PATH=$LUA_PATH ./pm.lua
else
    sudo LUA_PATH=$LUA_PATH ./pm.lua
fi
