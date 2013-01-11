#!/usr/bin/env python
# -*- coding: utf-8 -*-
# -*- Python -*-
#
# $Id: test_cover.py $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2013 cisco Systems, Inc.
#
# Created:       Fri Jan 11 12:05:58 2013 mstenber
# Last modified: Fri Jan 11 12:51:58 2013 mstenber
# Edit time:     22 min
#
"""

Calculate test coverage based on textual description of the tests.

Assumed format:

Each (set of) requirements a single paragraph, starting with [

It may have prefix of +-!

+ = covered by tests
- = not yet covered by tests
! = not applicable

TODO: This code will produce statistics of that (and ASCII art, using
ms.ascii from http://www.employees.org/~mstenber/ms.tar.gz )

It also is sensitive to MUST and SHOULD texts within paragraphs, and
categorizes the tests appropriately.

"""

import re

start_re = re.compile('^([\+\-\!]|)\[[^\]]+\] (.*)$').match
end_re = re.compile('^\s*$').match

should_re = re.compile('SHOULD').findall
must_re = re.compile('MUST').findall


class Statement:
    def __init__(self, letter, text):
        self.letter = letter
        self.l = [text]
    def text(self):
        return "\n".join(self.l)
    def should_count(self):
        return len(should_re(self.text()))
    def must_count(self):
        return len(must_re(self.text()))

class Spec:
    def __init__(self, filename):
        self.l = []
        self.parseLines(open(filename))
    def parseLines(self, lines):
        state = 0
        t = None
        for line in lines:
            if state == 0:
                m = start_re(line)
                if m is not None:
                    state = 1
                    t = Statement(m.group(1), m.group(2))
                    self.l.append(t)
            else:
                m = end_re(line)
                if m is not None:
                    state = 0
                    continue
                t.l.append(line.strip())
    def shoulds(self):
        return filter(lambda x:x.should_count()>0, self.l)
    def musts(self):
        return filter(lambda x:x.must_count()>0, self.l)

def summarize(l, verbose=False):
    def _x(prefix, letter):
        fl = filter(lambda x:x.letter == letter, l)
        if fl:
            print ' ', prefix, len(fl)
    def _y(prefix, letter):
        fl = filter(lambda x:x.letter == letter, l)
        if fl:
            print prefix
            for s in fl:
                print s.text()
                print
    if verbose:
        print
        _y('todo', '-')
        #_y('n/a', '!')
    _x('done', '+')
    _x('pending', '')
    _x('todo', '-')
    _x('n/a', '!')


if __name__ == '__main__':
    import sys
    filename = sys.argv[1] # give at least 1 argument
    s = Spec(filename)
    l = s.shoulds()
    print 'SHOULDs', len(l)
    summarize(l)
    l = s.musts()
    print 'MUSTs', len(l)
    summarize(l, len(sys.argv)>2)

