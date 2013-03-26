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
# Last modified: Tue Mar 26 16:11:56 2013 mstenber
# Edit time:     20 min
#

# start CONFIG
# reload CONFIG
# or
# stop

# Hardcoded dnsmasq path for UML/NetKit
UML_DNSMASQ=/hosthome/uml/debian-bin/dnsmasq

# Hardcoded dnsmasq part for OWRT AA (which has 'default' dnsmasq at
# /usr/sbin, which is rather old)
AA_DNSMASQ=/usr/sbin/hnet-dnsmasq

start() {
    CONF=$1
    if [ -x $AA_DNSMASQ ]
    then
        # Create directory for leases, if it's missing
        mkdir -p /var/lib/misc
        $AA_DNSMASQ -C $CONF
    elif [ -x $UML_DNSMASQ ]
    then
        $UML_DNSMASQ -C $CONF
    else
        dnsmasq -C $CONF
    fi
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall -9 dnsmasq hnet-dnsmasq 2>&1 > /dev/null
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
