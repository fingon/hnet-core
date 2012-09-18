TESTS=$(wildcard busted_*.lua)
SMC=../smc/bin/smc.jar

all: test

cov: test
#	(cd /usr/local/bin && luacov)
#	mv /usr/local/bin/luacov.report.out .
	mv /usr/local/bin/luacov.stats.out .
	luacov

test: .tested

skv_sm.lua: skv.sm
	java -jar $(SMC) -g -lua skv.sm
	java -jar $(SMC) -graph -glevel 2 skv.sm
	dot -Tpdf < skv_sm.dot > skv_sm.pdf

.tested: skv_sm.lua $(TESTS) $(wildcard *.lua)
	busted busted_tests.lua
#	touch $@
