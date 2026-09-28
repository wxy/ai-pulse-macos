# PR #91 final Swift checks (2026-09-28)

Run from the repository root on macOS arm64 with Xcode's Swift toolchain, already resolved SwiftPM dependencies, and permission to create Git repositories and linked worktrees in the system temporary directory. `RepositoryScopeTests` uses a real temporary linked worktree; a restricted process sandbox makes that fixture's `/usr/bin/git` calls fail with exit 128. No user repositories or databases are altered.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/aipulse-pr91-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/aipulse-pr91-module-cache \
swift test --disable-sandbox --disable-automatic-resolution \
  > /private/tmp/aipulse-pr91-full-test-final.log 2>&1
git diff --check
```

Result on 2026-09-28: the Swift command exited 0; 520 tests executed, 4 skipped, 0 failures. `git diff --check` exited 0. The log path above is the generated artifact and rerunning the command regenerates it. The focused export, Gemini, and iPhone simulator inputs and outcomes are recorded in the adjacent PR #91 verification documents.
