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
# Last modified: Wed Apr 10 15:41:13 2013 mstenber
# Edit time:     23 min
#

# start CONFIG
# reload CONFIG
# or
# stop

# Take UML config if applicable
if [ -f /usr/bin/hnetenv.sh ]
then
    # Hardcoded dnsmasq path for UML/NetKit
    . /usr/bin/hnetenv.sh
    DNSMASQ=$HNET/build/bin/dnsmasq
else
    # Hardcoded dnsmasq part for OWRT AA (which has 'default' dnsmasq at
    # /usr/sbin, which is rather old)
    DNSMASQ=/usr/sbin/hnet-dnsmasq
fi

start() {
    CONF=$1
    if [ -x $DNSMASQ ]
    then
        # Create directory for leases, if it's missing
        mkdir -p /var/lib/misc
        $DNSMASQ -C $CONF
    else
        dnsmasq -C $CONF
    fi
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall -9 `basename $DNSMASQ` 2>&1 > /dev/null
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
