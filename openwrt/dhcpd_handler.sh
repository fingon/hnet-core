#!/bin/sh
#-*-sh-*-
#
# $Id: dhcpd_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Tue Oct 30 14:40:44 2012 mstenber
# Last modified: Wed Mar 13 13:13:29 2013 mstenber
# Edit time:     12 min
#

AF=$1
COUNT=$2
CONFFILE=$3
PIDFILE=/tmp/dhcpd-$AF.pid
LOGFILE=/tmp/dhcpd-$AF.log

stop() {
    if [ -f $PIDFILE ]
    then
        kill -9 `cat $PIDFILE`
        rm -f $PIDFILE
        echo "Killed at " `date` >> $LOGFILE
    fi
}

start() {
    echo "Started at " `date` >> $LOGFILE
    dhcpd -$AF -d -cf $CONFFILE -pf $PIDFILE 2>&1 >> $LOGFILE &
}

if [ "$COUNT" = "0" ]
then
    stop
else
    stop
    start
fi

