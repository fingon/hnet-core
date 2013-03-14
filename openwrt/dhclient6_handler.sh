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
# Last modified: Wed Mar 13 23:46:33 2013 mstenber
# Edit time:     61 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf
LEASEFILE=/tmp/dhclient6-$IF.lease
LOGFILE=/tmp/dhclient6-$IF.log

start() {
    echo "Starting at "`date` >> $LOGFILE

    # Use this to produce debug log (probably good idea)
    # (s/-d/-nw/, remove tee + &, for no-debug version)
    dhclient -d -v -6 -D LL -P -cf $CONFFILE -pf $PIDFILE -lf $LEASEFILE $IF 2>&1 >> $LOGFILE &
    while [ ! -f $PIDFILE ]
    do
        sleep 1
    done
}

stop() {
    if [ ! -f $PIDFILE ]
    then
        return
    fi
    echo "Killing at "`date` >> $LOGFILE
    kill -9 $PIDFILE
    rm -f $PIDFILE
}


case $CMD in
    start)
        stop
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
