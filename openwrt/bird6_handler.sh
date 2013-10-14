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
# Last modified: Mon Oct 14 10:52:38 2013 mstenber
# Edit time:     61 min
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
    IFLIST=`echo "$IFLIST" | sed 's/ /","/g'`
    cat > $CONF <<EOF

#log "/tmp/bird6.log" all;
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
        area 0.0.0.0 {
                stub no;
                interface "$IFLIST" {
                        hello 10; dead count 4;
                        # This is also semi-crucial, as it affects
                        # default LSA max size (default is <3kb, which
                        # is ridiculously small for AC LSAs with lot of content)
                        rx buffer large;
                };
                interface "*" {
                        # We're aware of non-hnet interfaces, but
                        # as they're in practise external, set very high 
                        # cost here so that nobody can steal in-home traffic
                        # with e.g. SLAAC of in-home prefixes..
                        stub yes;
                        cost 200; 
                };
        };
}

EOF
    if [ -d /hosthome ]
    then
        # Log to specific magic directory if under NetKit
        HOSTNAME=`cat /proc/sys/kernel/hostname`
        # Netkit debugging log storage elsewhere than the virtual machine
        LOGDIR=/hostlab/logs/$HOSTNAME
        mkdir -p $LOGDIR
        #, packets
        echo "debug protocols {states, routes, filters, interfaces, events};" >> $CONF
        echo "log \"$LOGDIR/bird6.log\" all;" >> $CONF
    else
        # Log to syslog by default
        echo 'log syslog all;' >> $CONF
    fi
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
