.PHONY: build test run restart hup clean app run-app

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

# Build the distributable .app bundle (release binary + .icns + .png).
# NOTE: `swift build` / `make restart` only build the raw binary — the .app
# bundle (what you launch and what shows the Dock icon) is ONLY produced here.
app:
	bash scripts/build-app.sh

# Rebuild the .app bundle and relaunch it. Use this to see icon changes.
run-app: app
	@pkill -f "\.build/AIPulse.app" 2>/dev/null; sleep 1; open .build/AIPulse.app

clean:
	rm -rf .build
