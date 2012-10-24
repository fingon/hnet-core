#!/bin/bash -ue
#-*-sh-*-
#
# $Id: run_luacov.sh $
#
# Author: Markus Stenberg <fingon@iki.fi>
#
#  Copyright (c) 2012 cisco Systems, Inc.
#       All rights reserved
#
# Created:       Tue Oct  2 13:01:33 2012 mstenber
# Last modified: Tue Oct  2 13:03:23 2012 mstenber
# Edit time:     1 min
#

BASENAME=luacov.stats.out

for TPATH in /opt/local/share/luarocks/bin /usr/local/bin
do
    FPATH=$TPATH/$BASENAME
    if [ -f $FPATH  ]
    then 
        mv $FPATH .
	exec luacov
    fi
done
if [ -f $BASENAME ]
then
    exec luacov
fi
echo "No $BASENAME to be found!"
exit 1
