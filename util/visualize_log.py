#!/usr/bin/env python
# -*- coding: utf-8 -*-
# -*- Python -*-
#
# $Id: visualize_log.py $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#
# Created:       Sun Nov  4 09:31:52 2012 mstenber
# Last modified: Sun Nov  4 10:34:03 2012 mstenber
# Edit time:     20 min
#
"""

Visualize one or more logs in Python.

Output is a single graph file, with the different criteria(/files) as
different axes.

This would be probably easier with matplotlib; but gnuplot is familiar ;)

"""

import re
import ms.container

ts1_re = re.compile('^(?P<d>\d+)-(?P<m>\d+)-(?P<y>\d+) (?P<H>\d+):(?P<M>\d+):(?P<S>\d+) (?P<text>.*)$').match
ts2_re = re.compile('^(?P<wd>[A-Z][a-z]+)\s+(?P<mon>[A-Z][a-z]+)\s+(?P<d>\d+)\s+(?P<H>\d+):(?P<M>\d+):(?P<S>\d+)\s+(?P<y>\d+)\s+(?P<text>.*)$').match

tl1 = "08-09-2011 18:51:14 <TRACE> kernel1: Initializing"
tl2 = "Thu Sep  8 18:51:13 2011 initializing skv"
assert ts1_re(tl1) is not None
assert ts2_re(tl2) is not None

def process(files_matches):
    #gp = Gnuplot.Gnuplot()
    for i in range(0, len(files_matches), 2):
        f = open('file%d.dat' % (i/2), 'w')
        filename = files_matches[i]
        matching = files_matches[i+1]
        match = re.compile(matching).match
        r = ms.container.CounterDict()
        for line in open(filename):
            found = False
            for ts in [ts1_re, ts2_re]:
                m = ts(line)
                if m is not None:
                    found = True
                    d = m.groupdict()
                    v = (int(d['H']) * 60 + (int(d['M']))) * 60 + int(d['S'])
                    text = d['text']
            if not found:
                continue
            if not match(text):
                continue
            r.add(v)
        kl = r.keys()
        kl.sort()
        last = None
        for k in kl:
            if last and last < (k - 2):
                f.write('%s 0\n' % (last+1))
                f.write('%s 0\n' % (k-1))

            f.write('%s %s\n' % (k, r[k]))
            last = k
if __name__ == '__main__':
    import sys
    args = sys.argv[1:]
    if not args:
        args = ['/Users/mstenber/bird6.log', '.*',
                '/Users/mstenber/pm.log', '.*']
        print 'using default arguments', args
    process(args)



