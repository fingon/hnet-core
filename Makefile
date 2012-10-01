LUA_SMS=skv_sm.lua elsa_pa_sm.lua
TESTS=$(wildcard spec/*.lua)
SMC=../smc/bin/smc.jar

all: test

cov: test
#	(cd /usr/local/bin && luacov)
#	mv /usr/local/bin/luacov.report.out .
	mv /usr/local/bin/luacov.stats.out .
	luacov

test: .tested

%_sm.lua: %.sm
	java -jar $(SMC) -g -lua $<
	java -jar $(SMC) -graph -glevel 2 $<
	dot -Tpdf < $*_sm.dot > $*_sm.pdf

.tested: skv_sm.lua $(TESTS) $(wildcard *.lua)
	busted spec
#	touch $@
