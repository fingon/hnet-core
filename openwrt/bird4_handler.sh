#!/bin/sh 
#-*-sh-*-
#
# $Id: bird_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Mon Nov  5 05:49:41 2012 mstenber
# Last modified: Tue Mar 26 16:11:59 2013 mstenber
# Edit time:     17 min
#

# Start or stop bird4 (for 'home' routing)
# Call syntax should be either

# start RID
# or
# stop

CONF=/tmp/pm-bird4.conf

start() {
    RID=$1
cat > $CONF <<EOF

log "/tmp/bird4.log" all;
#log syslog all;

debug protocols {states, routes, filters, interfaces, events, packets};

router id $RID;

protocol device {
        scan time 10;
}

# protocol direct is implicit

protocol kernel {
        learn; # learn alien routes from kernel
        persist;
        device routes;
        import all;
        export all;
        scan time 15;
}

protocol ospf {
        import all;
        export all;

        area 0 {
                # We talk with about anyone with the password.. ;-)
                interface "*" {
                        hello 5; retransmit 2; wait 10; dead count 4;
                        authentication cryptographic; password "foo";
                };

#                interface "*" {
#                        cost 1000;
#                        stub;
#                };
        };
}

EOF
    bird4 -c $CONF
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall -9 bird4 2>&1 > /dev/null
}

CMD=$1

case $CMD in
    start)
        stop
        start $2
        ;;
    stop)
        stop
        ;;
    *)
        echo "Only start/stop supported"
        exit 1
        ;;
esac
