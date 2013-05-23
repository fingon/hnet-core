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
# Last modified: Tue Nov 20 17:10:08 2012 mstenber
# Edit time:     14 min
#

# Start or stop listening to ra default router info on apsecific interface
# Call syntax should be either

# start if
# or
# stop if


start() {
    IF=$1
    KERN=`uname -r | awk -F. '{ printf("%d.%d\n",$1,$2); }'`
    if [ "$KERN" \< "3.1" ]
    then
        # Rather ugly hack - set forwarding on _that_ interface to 0
        # so it will accept RA's

        # (It doesn't seem to affect actual forwarding, as long as
        # all/forwarding > 0)
        echo 0 > /proc/sys/net/ipv6/conf/$IF/forwarding
    fi

    echo 0 > /proc/sys/net/ipv6/conf/$IF/accept_ra_pinfo
    echo 2 > /proc/sys/net/ipv6/conf/$IF/accept_ra

    # This is strictly optional package, but proactively doing rdisc6
    # gets the information to kernel too much faster. If not available,
    # no harm, no foul..
    rdisc6 $IF > /dev/null &
}

stop() {
    IF=$1
    echo 1 > /proc/sys/net/ipv6/conf/$IF/accept_ra
    echo 1 > /proc/sys/net/ipv6/conf/$IF/accept_ra_pinfo
    # XXX - should we restore the forwarding flag here, or not? Sad
    # thing is, we don't know what value it was at..
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
