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
# Last modified: Tue Mar 12 02:00:29 2013 mstenber
# Edit time:     13 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf
LEASEFILE=/tmp/dhclient6-lease.$IF

case $CMD in
    start)
        dhclient -6 -D LL -nw -P -cf $CONFFILE -pf $PIDFILE -lf $LEASEFILE $IF
        ;;
    stop)
        dhclient -6 -x -pf $PIDFILE
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
