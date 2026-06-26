.PHONY: build test run restart clean

build:
	swift build

test:
	swift test

run:
	swift run

restart:
	killall AIPulse 2>/dev/null || true
	sleep 1
	swift run

clean:
	rm -rf .build
