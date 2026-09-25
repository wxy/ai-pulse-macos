.PHONY: build test run restart hup clean publish-release

LIBGIT2_LIB := $(PWD)/Libraries/libgit2/lib

build:
	swift build

test:
	swift build --build-tests -Xcc -I$(PWD)/Libraries/libgit2/include
	@BIN_DIR=$$(swift build --show-bin-path) && \
	TEST_BIN="$$BIN_DIR/AIPulsePackageTests.xctest/Contents/MacOS/AIPulsePackageTests" && \
	otool -l "$$TEST_BIN" | grep -q "$(LIBGIT2_LIB)" || \
		install_name_tool -add_rpath "$(LIBGIT2_LIB)" "$$TEST_BIN"; \
	swift test --skip-build -Xcc -I$(PWD)/Libraries/libgit2/include

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

# Promote a draft GitHub Release to public after App Store approval.
# Usage: make publish-release VERSION=1.2.6
publish-release:
	@test -n "$(VERSION)" || (echo "Usage: make publish-release VERSION=1.2.6"; exit 1)
	gh release edit "v$(VERSION)" --draft=false

clean:
	rm -rf .build
