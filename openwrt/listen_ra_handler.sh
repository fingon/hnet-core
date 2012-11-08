#!/bin/sh 
#-*-sh-*-
#
# $Id: listen_ra_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Thu Nov  8 10:02:26 2012 mstenber
# Last modified: Thu Nov  8 10:04:30 2012 mstenber
# Edit time:     2 min
#

# Start or stop listening to ra default router info on apsecific interface
# Call syntax should be either

# start if
# or
# stop if

start() {
    IF=$1
    echo 2 > /proc/sys/net/ipv6/conf/$IF/accept_ra
    echo 0 > /proc/sys/net/ipv6/conf/$IF/accept_ra_pinfo
}

stop() {
    IF=$1
    echo 1 > /proc/sys/net/ipv6/conf/$IF/accept_ra
    echo 1 > /proc/sys/net/ipv6/conf/$IF/accept_ra_pinfo
}

CMD=$1
IF=$2

case $CMD in
    start)
        start $IF
        ;;
    stop)
        stop $IF
        ;;
    *)
        echo "Only start/stop supported"
        exit 1
        ;;
esac
