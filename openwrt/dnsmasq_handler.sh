#!/bin/bash -ue
#-*-sh-*-
#
# $Id: dnsmasq_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Wed Nov 21 19:17:00 2012 mstenber
# Last modified: Wed Nov 21 19:19:24 2012 mstenber
# Edit time:     2 min
#

# start CONFIG
# reload CONFIG
# or
# stop

UML_DNSMASQ=/hosthome/uml/dnsmasq/dnsmasq

start() {
    CONF=$1
    if [ -f $UML_DNSMASQ ]
    then
        $UML_DNSMASQ -C $CONF
    else
        dnsmasq -C $CONF
    fi
}

reload() {
    CONF=$1
    killall -HUP dnsmasq || start $CONF
}

stop() {
    killall dnsmasq
}

CMD=$1

case $CMD in
    start)
        stop
        start $2
        ;;
    reload)
        reload $2
        ;;
    stop)
        stop
        ;;
    *)
        echo "Only start/reload/stop supported"
        exit 1
        ;;
esac
