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
# Last modified: Mon Feb  4 16:13:15 2013 mstenber
# Edit time:     2 min
#

# Enable this if stuff doesn't terminate
#exec lua -lluacov -lluacov.tick $*

# With this, we write luacov stats just at the end
exec lua -lluacov $*
