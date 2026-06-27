.PHONY: build test run restart hup clean

build:
	swift build

test:
	swift test

run:
	swift run

restart:
	-killall -9 AIPulse 2>/dev/null
	-pkill -9 -f "\.build/.*AIPulse" 2>/dev/null
	# Wait for system to release the menu-bar slot (needs >1 s on Apple Silicon)
	sleep 3
	swift run

# Graceful restart via SIGHUP — keeps DB connections clean
hup:
	pkill -HUP -f "\.build/.*AIPulse"

clean:
	rm -rf .build
