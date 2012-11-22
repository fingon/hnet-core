#!/bin/sh
#-*-sh-*-
#
# $Id: dnsmasq_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Wed Nov 21 19:17:00 2012 mstenber
# Last modified: Thu Nov 22 10:46:06 2012 mstenber
# Edit time:     11 min
#

# start CONFIG
# reload CONFIG
# or
# stop

UML_DNSMASQ=/hosthome/uml/dnsmasq/dnsmasq

start() {
    CONF=$1
    # Use dnsmasq binary on non-OpenWRT,
    # with /hosthome available
    if [ -f $UML_DNSMASQ -a ! -d /etc/config ]
    then
        $UML_DNSMASQ -C $CONF
    else
        dnsmasq -C $CONF
    fi
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall -9 dnsmasq || true
}

reload() {
    CONF=$1
    # In ideal world, we would use SIGHUP and dnsmasq would read it's
    # config again. But it doesn't, it just re-reads lease DB and some other
    # stuff. sigh.
    #
    #killall -HUP dnsmasq || start $CONF

    # So..
    stop 
    start $CONF
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
