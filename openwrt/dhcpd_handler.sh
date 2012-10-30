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
# Last modified: Tue Oct 30 14:52:41 2012 mstenber
# Edit time:     4 min
#

AF=$1
COUNT=$2
PIDFILE=$3
CONFFILE=$4

stop() {
    if [ -f $PIDFILE ]
    then
        kill `cat $PIDFILE`
        rm -f $PIDFILE
    fi
}

start() {
    dhcpd -$AF -cf $CONFFILE -pf $PIDFILE
}

if [ "$COUNT" = "0" ]
then
    stop
else
    stop
    start
fi

