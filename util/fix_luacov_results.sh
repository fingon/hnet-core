#!/bin/bash -ue
#-*-sh-*-
#
# $Id: fix_luacov_results.sh $
#
# Author: Markus Stenberg <markus stenberg@iki.fi>
#
# Copyright (c) 2013 cisco Systems, Inc.
#
# Created:       Tue Feb  5 11:38:38 2013 mstenber
# Last modified: Tue Feb  5 11:43:29 2013 mstenber
# Edit time:     5 min
#

# Luacov has annoying habit of not noticing several things - this is
# ugly way to fix them (by just editing the luacov.report.out directly).

cat luacov.report.out | 
perl -p -e 's/^\*\*\*\*\*\*0(\s+)then\s*$/      0$1then\n/' |
perl -p -e 's/^\*\*\*\*\*\*0(.*function.*)$/      0$1/' > luacov.report.fixed

