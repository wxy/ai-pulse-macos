.PHONY: build test run restart hup clean

LIBGIT2_LIB := $(PWD)/Libraries/libgit2/lib

build:
	swift build

test:
	DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift test

run:
	DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift run

# Build + graceful restart. Sends SIGHUP if running, starts fresh if not.
restart: build
	@if pgrep -qf "\.build/.*AIPulse"; then \
		pkill -HUP -f "\.build/.*AIPulse"; \
	else \
		DYLD_LIBRARY_PATH=$(LIBGIT2_LIB) swift run & \
	fi

# Graceful restart via SIGHUP — keeps DB connections clean
hup:
	pkill -HUP -f "\.build/.*AIPulse"

clean:
	rm -rf .build
