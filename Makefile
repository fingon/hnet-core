LUA_SMS=skv_sm.lua pa_lap_sm.lua
TESTS=$(wildcard spec/*.lua)
SMC=../smc/bin/smc.jar

all: test

cov: test
	COMMAND="lua -lluacov" busted spec
	./run_luacov.sh

test: .tested

%_sm.lua: %.sm
	java -jar $(SMC) -g -lua $<
	java -jar $(SMC) -graph -glevel 2 $<
	dot -Tpdf < $*_sm.dot > $*_sm.pdf

.tested: skv_sm.lua $(TESTS) $(wildcard *.lua)
	busted spec
	ENABLE_MST_DEBUG=1 busted spec 2>&1 | grep successes
#	touch $@
