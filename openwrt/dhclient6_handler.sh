#!/bin/sh
#-*-sh-*-
#
# $Id: dhclient6_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Fri Nov 16 13:10:54 2012 mstenber
# Last modified: Tue Oct 29 09:00:54 2013 mstenber
# Edit time:     91 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf
LEASEFILE=/tmp/dhclient6-$IF.lease
LOGFILE=/tmp/dhclient6-$IF.log


BIN=odhcp6c
#SOL_TIMEOUT is used by odhcpv6c as the maximum time between soliciations
SOL_TIMEOUT=30
UMLPATH=/hosthome/uml/debian-bin

# Do this only on UML, not real OWRT
if [ -f /usr/bin/luaenv.sh -a ! -d /etc/config ]
then
    # get odhcp6c to path from hnet/build
    . /usr/bin/luaenv.sh
fi

SCRIPT_BASE=odhcp6c_handler.lua

SCRIPT=/usr/share/lua/$SCRIPT_BASE
if [ ! -f $SCRIPT ]
then
    SCRIPT=$CORE/$SCRIPT_BASE
    if [ ! -f $SCRIPT ]
    then
        echo "Unable to find script $SCRIPT"
        exit 1
    fi
fi

# .. just in case..
if [ ! -x $SCRIPT ]
then
    chmod a+x $SCRIPT
fi

start() {
    echo "Starting at "`date` >> $LOGFILE

    # Use this to produce debug log (probably good idea)
    # (s/-d/-nw/, remove tee + &, for no-debug version)

    # ISC - but this won't work with more than one interface, unfortunately
    #dhclient -d -v -6 -D LL -P -cf $CONFFILE -pf $PIDFILE -lf $LEASEFILE $IF 2>&1 >> $LOGFILE &

    # odhcp6c
    $BIN -P 0 -F -s $SCRIPT -p $PIDFILE -d $IF -t $SOL_TIMEOUT

    while [ ! -f $PIDFILE ]
    do
        sleep 1
    done
}

stop() {
    if [ ! -f $PIDFILE ]
    then
        return
    fi
    echo "Killing at "`date` >> $LOGFILE
    kill -9 `cat $PIDFILE`
    rm -f $PIDFILE
    sleep 1
}


case $CMD in
    start)
        stop
        start
        ;;
    stop)
        stop
        ;;
    *)
        echo "Unknown command - only start/stop supported"
        ;;
esac
