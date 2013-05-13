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
# Last modified: Mon May 13 17:24:14 2013 mstenber
# Edit time:     7 min
#

# Luacov has annoying habit of not noticing several things - this is
# ugly way to fix them (by just editing the luacov.report.out directly).


# (also two varisnts seem to be in wild - 6 *'s, and 8 *'s, sigh)
cat luacov.report.out | 
perl -p -e 's/^\*\*\*\*\*\*0(\s+)then\s*$/      0$1then\n/' |
perl -p -e 's/^\*\*\*\*\*\*\*0(\s+)then\s*$/       0$1then\n/' |
perl -p -e 's/^\*\*\*\*\*\*\*\*0(\s+)then\s*$/        0$1then\n/' |
perl -p -e 's/^\*\*\*\*\*\*0(.*function.*)$/      0$1/' | \
perl -p -e 's/^\*\*\*\*\*\*\*0(.*function.*)$/       0$1/' | \
perl -p -e 's/^\*\*\*\*\*\*\*\*0(.*function.*)$/        0$1/' | \
cat > luacov.report.fixed

