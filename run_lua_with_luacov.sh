#!/bin/bash -ue
#-*-sh-*-
#
# $Id: run_lua_with_luacov.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Tue Nov 13 13:17:58 2012 mstenber
# Last modified: Tue Nov 13 13:24:06 2012 mstenber
# Edit time:     1 min
#

exec lua -lluacov -lluacov.tick $*
