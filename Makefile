TESTS=$(wildcard busted_*.lua)
SMC=../smc/bin/smc.jar

all: test

test: .tested

skv_sm.lua: skv.sm
	java -jar $(SMC) -g -lua skv.sm
	java -jar $(SMC) -graph -glevel 2 skv.sm
	dot -Tpdf < skv_sm.dot > skv_sm.pdf

.tested: skv_sm.lua $(TESTS) $(wildcard *.lua)
	busted busted_tests.lua
#	touch $@
