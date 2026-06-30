.PHONY: build test run restart hup clean

LIBGIT2_LIB := $(PWD)/Libraries/libgit2/lib

build:
	swift build

test:
	DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift test

run:
	DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift run

restart:
	-killall -9 AIPulse 2>/dev/null
	-pkill -9 -f "\.build/.*AIPulse" 2>/dev/null
	# Wait for system to release the menu-bar slot (needs >1 s on Apple Silicon)
	sleep 3
	DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift run

# Graceful restart via SIGHUP — keeps DB connections clean
hup:
	pkill -HUP -f "\.build/.*AIPulse"

clean:
	rm -rf .build
