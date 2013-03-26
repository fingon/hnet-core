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
# Last modified: Tue Mar 26 16:49:08 2013 mstenber
# Edit time:     78 min
#

CMD=$1
IF=$2
PIDFILE=$3
CONFFILE=/etc/dhcp/dhclient6-hnet.conf
LEASEFILE=/tmp/dhclient6-$IF.lease
LOGFILE=/tmp/dhclient6-$IF.log


BIN=odhcp6c
UMLPATH=/hosthome/uml/debian-bin

# Do this only on UML, not real OWRT
if [ -f $UMLPATH/$BIN -a ! -d /etc/config ]
then
    BIN=$UMLPATH/$BIN
fi

SCRIPT_BASE=odhcp6c_handler.lua
UMLLUAPATH=/hosthome/uml/bird/lua
OWRTLUAPATH=/usr/share/hnet

SCRIPT=$OWRTLUAPATH/$SCRIPT_BASE
if [ ! -f $SCRIPT ]
then
    SCRIPT=$UMLLUAPATH/$SCRIPT_BASE
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
    $BIN -N none -P 0 -s $SCRIPT -p $PIDFILE -d $IF

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
