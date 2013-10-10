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
# Last modified: Thu Oct 10 14:38:02 2013 mstenber
# Edit time:     22 min
#

# Start or stop bird4 (for 'home' routing)
# Call syntax should be either

# start [IF] [IF2] [...]
# or
# stop

if [ -f /usr/bin/hnetenv.sh ]
then
    . /usr/bin/hnetenv.sh
    BIRD4=$HNET/build/bin/bird4
    BIRDCTL4=$HNET/build/bin/birdc4
else
    BIRD4=bird4
    BIRDCTL4=birdc4
fi

CONF=/tmp/pm-bird4.conf
PIDFILE=/tmp/pm-bird6.pid

writeconf() {
    # Initially interface list is "if1 if2 if3"
    IFLIST=$*
    if [ "x$IFLIST" = "x" ]
    then
        IFLIST="*"
    else
        # Bird interface pattern looks like "if1","if2","if3" 
        # (first and last mark are taken care of by the config file below)
        IFLIST=`echo "$IFLIST" | sed 's/ /","/g'`
    fi
    cat > $CONF <<EOF

protocol kernel {
        learn; # learn alien routes from kernel
        persist;
        device routes;
        import all;
        export all;
        scan time 15;
}

protocol device {
        scan time 10;
}

# protocol direct is implicit

protocol ospf {
        import all;
        export all;

        area 0 {
                # We talk with about anyone with the password.. ;-)
                interface "$IFLIST" {
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
}


start() {
    $BIRD4 -c $CONF -P $PIDFILE
}

reconfigure() {
    $BIRDCTL4 configure
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall bird4 2>&1 > /dev/null
    rm -f $PIDFILE
}

CMD=$1

case $CMD in
    start)
        shift
        writeconf $*
        if [ -f $PIDFILE ]
        then
            reconfigure
        else
            start
        fi
        ;;
    stop)
        stop
        ;;
    *)
        echo "Only start/stop supported"
        exit 1
        ;;
esac
