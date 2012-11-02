#!/usr/bin/env python
# -*- coding: utf-8 -*-
# -*- Python -*-
#
# $Id: generate_kill_script.py $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Fri Nov  2 10:32:48 2012 mstenber
# Last modified: Fri Nov  2 10:46:17 2012 mstenber
# Edit time:     9 min
#
"""

Basic idea: Generate .sh script, which kills the selected set of
processes, and gets 'free' after each. This is workable solution to
get some idea of the system memory usage, if e.g. /proc/pid/smap is
not available.

There's two different scripts - normal order, reverse order.

Running both, taking averages => ~semi-scientifically-justifiable
median memory usage accounting for shared memory use between
processes.

"""

print '''#! /bin/sh
ps_kill() {
  TEXT="$*"
  PIDS=`ps | grep "$TEXT" | grep -v grep | cut -b 1-6`
  if [ "x$PIDS" = "x" ]
  then
    echo "$TEXT not found"
  else
    echo "Killing $TEXT - $PIDS"
    kill -9 $PIDS
    sleep 2
    free
  fi
}
free
'''

l = ['lua /usr/share/lua/pm.lua',
          'bird6-elsa',
          #'dhclient',
          'babeld',
          'dhcpd -4',
          'dhcpd -6',
          'dhclient -nw -pf', # dhcpv4 client
          'dhclient -nw -6 -P eth0.2',
          'dhclient -nw -6 -P eth0.3',
          'dhclient -nw -6 -P eth0.4',
          'dhclient -nw -6 -P eth1',
          'radvd']

l.reverse()

for i in l:
    print 'ps_kill "%s"' % i



