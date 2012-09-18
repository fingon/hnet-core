TESTS=$(wildcard busted_*.lua)

tested: $(TESTS)
	busted busted_tests.lua
	touch tested
