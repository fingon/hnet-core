#!/bin/bash -ue
#-*-sh-*-
#
# $Id: create_graph.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Sun Nov  4 10:11:31 2012 mstenber
# Last modified: Sun Nov  4 10:13:14 2012 mstenber
# Edit time:     2 min
#

BASE=`dirname $0`

if [ ! $# = 0 ]
then
    python $BASE/visualize_log.py $*
else
    python $BASE/visualize_log.py 'bird6.log' '.*' 'pm.log' '.*'
fi
gnuplot $BASE/foo.gnuplot
open foo.pdf
