.PHONY: check doctor test

check:
	./scripts/check

doctor:
	./scripts/doctor

test:
	bash tests/cmux-v5-lib-test.sh
