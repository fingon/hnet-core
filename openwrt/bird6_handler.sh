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
# Last modified: Wed Oct  9 17:24:48 2013 mstenber
# Edit time:     30 min
#

# Start or stop bird6
# Call syntax should be either

# start <IF1> [IF2] [...]
# or
# stop

if [ -f /usr/bin/hnetenv.sh -a ! -d /etc/config ]
then
    . /usr/bin/hnetenv.sh
    BIRD6=$HNET/build/bin/bird6
    BIRDCTL6=$HNET/build/bin/birdc6
else
    BIRD6=bird6-elsa
    BIRDCTL6=birdc6-elsa
fi

CONF=/tmp/pm-bird6.conf
PIDFILE=/tmp/pm-bird6.pid

writeconf() {
    # Initially interface list is "if1 if2 if3"
    IFLIST=$*
    # Bird interface pattern looks like "if1","if2","if3" 
    # (first and last mark are taken care of by the config file below)
    IFLIST=`echo "$IFLIST" | sed 's/ /","`
    cat > $CONF <<EOF

#log "/tmp/bird6.log" all;
log syslog all;
#debug protocols {states, routes, filters, interfaces, events, packets};

router id random;
router id remember "/tmp/pm-bird6.rid";

protocol kernel {
#        persist;               # Don't remove routes on bird shutdown
         scan time 20;          # Scan kernel routing table every 20 seconds
         export all;            # Default is export none
         device routes;         # Also export device routes to kernel routing table (XXX - is this a bug? sometimes OSPF-sourced routes have device as source, which sounds broken)
}


protocol device {
        scan time 10;
}

# protocol direct is implicit

protocol ospf {
        import all;
        duplicate rid detection yes;
        elsa path "/usr/share/bird/elsa.lua";
        area 0 {
                stub no;
                interface "$IFLIST" {
                        hello 10; dead count 4;
                };
        };
}

EOF
}

start() {
    $BIRD6 -c $CONF -P $PIDFILE
}

reconfigure() {
    $BIRDCTL6 configure
}

stop() {
    # -q would be nice, but not in busybox.. oh well.
    killall bird6-elsa 2>&1 > /dev/null
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
