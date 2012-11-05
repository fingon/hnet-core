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
# Last modified: Mon Nov  5 05:56:59 2012 mstenber
# Edit time:     3 min
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

log syslog all;

router id $RID;

protocol device {
        scan time 10;
}

protocol kernel {
        export all;
        scan time 15;
}

protocol ospf {
        import all;

        area 0 {
                interface "eth0.*", "eth1" {
                        hello 5; retransmit 2; wait 10; dead count 4;
                        authentication cryptographic; password "foo";
                };

                interface "*" {
                        cost 1000;
                        stub;
                };
        };
}

EOF
    bird4 -c $CONF
}

stop() {
    killall -9 bird4
}

case CMD in
    start)
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
