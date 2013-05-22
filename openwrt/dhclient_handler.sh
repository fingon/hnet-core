#!/bin/sh 
#-*-sh-*-
#
# $Id: dhclient_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Tue Oct 30 13:13:16 2012 mstenber
# Last modified: Tue Oct 30 13:42:00 2012 mstenber
# Edit time:     6 min
#

CMD=$1
IF=$2
PIDFILE=$3

case $CMD in
    start)
        dhclient -nw -pf $PIDFILE $IF
        ;;
    stop)
        kill `cat $PIDFILE`
        rm -f $PIDFILE
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
