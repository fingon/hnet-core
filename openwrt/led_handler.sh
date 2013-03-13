#!/bin/sh 
#-*-sh-*-
#
# $Id: led_handler.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2013 cisco Systems, Inc.
#
# Created:       Wed Mar 13 09:51:10 2013 mstenber
# Last modified: Wed Mar 13 10:09:01 2013 mstenber
# Edit time:     3 min
#

# This script handles led change events. Mainly, it maps the
# user-friendly names to ones on a box..

LEDNAME=$1
VALUE=$2
LEDPATH=
LEDBASE=/sys/class/leds

if [ $LEDNAME = "pd" ]
then
    # Blue = local PD prefix detected
    LEDPATH="buffalo:blue:movie_engine"
elif [ $LEDNAME = "global" ]
then
    # Green = global IPv6 address assigned
    LEDPATH="buffalo:green:router"
fi

if [ "x$LEDPATH" = "x" ]
then
    echo "Unknown led?!?"
    exit 1
fi

echo $VALUE > $LEDBASE/$LEDPATH/brightness
