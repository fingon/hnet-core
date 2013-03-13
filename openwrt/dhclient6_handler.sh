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
# Last modified: Wed Mar 13 14:14:22 2013 mstenber
# Edit time:     55 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf
LEASEFILE=/tmp/dhclient6-$IF.lease
LOGFILE=/tmp/dhclient6-$IF.log

case $CMD in
    start)
        if [ -f $PIDFILE ]
        then
            dhclient -6 -x -pf $PIDFILE
            sleep 1
        fi
        if [ ! "x$IF" = "xeth1" ]
        then
            echo "Ignoring request to start on $IF" >> $LOGFILE
            exit 1
        fi

        echo "Starting at "`date` >> $LOGFILE

        # Use this to produce debug log (probably good idea)
        # (s/-d/-nw/, remove tee + &, for no-debug version)
        dhclient -d -v -6 -D LL -P -cf $CONFFILE -pf $PIDFILE -lf $LEASEFILE $IF 2>&1 | tee -a $LOGFILE &

        ;;
    stop)
        echo "Killed at "`date` >> $LOGFILE
        dhclient -6 -x -pf $PIDFILE
        rm -f $PIDFILE
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
