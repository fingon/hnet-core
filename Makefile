#
# Author: Markus Stenberg <fingon@iki.fi>
#
# Copyright (c) 2012 cisco Systems, Inc.
#

LUA_SMS=skv_sm.lua pa_lap_sm.lua
TESTS=$(wildcard spec/*.lua)
SMC=../smc/bin/smc.jar

all: test

clean:
	rm -f luacov.stats.out luacov.report.out

cov: clean test
	busted -l "./run_lua_with_luacov.sh" spec
	./run_luacov.sh

mem:
	./run_lua_memory_stats.sh | sort -n

stress: .stressed

test: .tested

%_sm.lua: %.sm
	java -jar $(SMC) -g -lua $<
	java -jar $(SMC) -graph -glevel 2 $<
	dot -Tpdf < $*_sm.dot > $*_sm.pdf

debug:
	ENABLE_MST_DEBUG=1 busted spec

.stressed: $(LUA_SMS) $(TESTS) $(wildcard *.lua)
	busted -p '_stress.lua$$' stress

.tested: $(LUA_SMS) $(TESTS) $(wildcard *.lua)
	busted spec
#	ENABLE_MST_DEBUG=1 busted spec 2>&1 | grep successes
#	touch $@
