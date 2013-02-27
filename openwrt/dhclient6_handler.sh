#!/bin/sh
#-*-sh-*-
#
# $Id: dhclient6_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Fri Nov 16 13:10:54 2012 mstenber
# Last modified: Wed Feb 27 13:53:27 2013 mstenber
# Edit time:     3 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf

case $CMD in
    start)
        dhclient -6 -nw -P -cf $CONFFILE -pf $PIDFILE $IF
        ;;
    stop)
        kill `cat $PIDFILE`
        rm -f $PIDFILE
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
