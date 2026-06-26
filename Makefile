.PHONY: build test run restart clean

build:
	swift build

test:
	swift test

run:
	swift run

restart:
	killall -9 AIPulse 2>/dev/null || true
	pkill -9 -f "\.build/.*AIPulse" 2>/dev/null || true
	sleep 2
	swift run

clean:
	rm -rf .build
