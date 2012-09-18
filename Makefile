TESTS=$(wildcard busted_*.lua)
SMC=../smc/bin/smc.jar

x:
	java -jar $(SMC) -lua skv.sm
	java -jar $(SMC) -graph -glevel 2 skv.sm
	dot -Tpdf < skv_sm.dot > skv_sm.pdf
tested: $(TESTS)
	busted busted_tests.lua
	touch tested
