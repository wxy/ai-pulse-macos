# Local processing status verification — 2026-10-23

## Failure modes and validation plan (before implementation)

- Existing checkpoints and cached history bypass the cold-import flag; queued or running warm catch-up still needs a busy status.
- Directory reading, file parsing, checkpoint writes, session metadata, cache invalidation/debounce and dashboard preparation must hand off without a false idle gap.
- Concurrent or queued scans/preparations must not clear one another; an older completed/cancelled task must not mutate a newer task.
- Cancellation, early return, missing optional inputs and failures must release task ownership without a stuck busy indicator.
- Permission, source-read and query failures take priority over processing; processing takes priority over stale/empty placeholders and the activity curve.
- Opening/reopening the dashboard mid-work must show the current stage; changing ranges or cancelling a stale load must retain any other pending work.
- Fast per-file updates must not flood the main queue; phase messages must be localized and avoid invented percentages.
- Completion must restore the activity curve only after all local processing and snapshot publication finish.

Use filesystem → production LogWatcher → isolated SQLite → dashboard preparation/UI for the primary check, including a warm resume after appended input. UI timing alone cannot reliably force concurrent completion/cancellation orders, so an isolated lifecycle check is required for that state owner. Its five temporary checks were written before implementation in an ignored test folder and cover handoff, overlap/late callbacks, release, concurrent ownership and coalesced main-thread delivery. Retain this report only; remove the temporary checks, synthetic input, database, builds and logs after recording actual results.

## Implementation

`LocalDataProcessing` gives queued/running work independent lifetime handles, even when an older scan or cache is usable. Source reads/parsing take priority over derived-data preparation. Completion, early return and cancellation release ownership; late updates cannot revive finished work. Main-thread notifications coalesce rapid transitions.

Entry points cover initial/warm LogWatcher scans, parsing/checkpoints, repository/Git reads, session metadata, cache invalidation/debounced publication, shared snapshot building and dashboard loads. Notification handoff retains preparation until the dashboard acquires its own load handle. Permission and local read/query failures take priority. Completion returns directly to the activity wave.

## Environment and commands

macOS 26.6.2 (25G83), Xcode 27.1 (27A9275), arm64. Synthetic input and all build artifacts were under `/private/tmp/aipulse-processing-qa`. The separate sandbox bundle was `xingyu.wang.aipulse.runtimeqa`; existing normal and unsandboxed QA profiles were not used.

```sh
swift test --scratch-path /private/tmp/aipulse-processing-qa/swift --jobs 4 \
  --filter 'LocalDataProcessing|LogScanObservation|LocalDataStatus|DataRefreshCoordinator|RepoScanCache|SymlinkTracking|SessionInfoBackfill'
swift test --scratch-path /private/tmp/aipulse-processing-qa/swift --skip-build
xcodebuild -workspace AIPulse.xcworkspace -scheme AIPulse_macOS \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/aipulse-processing-qa/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
python3 scripts/check-localizations.py
git diff --check
```

All passed: 32 focused checks, including five temporary lifecycle checks written before implementation. Full regression: 532 tests, 528 passed, 4 explicit-private-input checks skipped, 0 failures. The five temporary checks are removed after reporting; the permanent suite is unchanged. Existing injected-database symlink cases log shared `DashboardCache` AppDBError 0 because that global cache database is uninitialized in those cases; their assertions pass. Actual app/database acceptance below is separate.

The final normal macOS Debug build passed after restoring production source bytes and removing QA instrumentation. Localization validation passed: 778 active keys, 10 locales, 416 inline pairs. Diff checks passed.

## Actual application verification

The initial QA build added `PRODUCT_BUNDLE_IDENTIFIER=xingyu.wang.aipulse.runtimeqa` and `SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG PROCESSING_QA'`. Temporary instrumentation redirected the real-home getter to the fixture home, added menu actions calling production entry points, and passively recorded actual forehead text/stage. RuntimeQA kept normal collectors, accounts and cloud startup disabled. The real `NSOpenPanel` granted only the synthetic folder.

The copy `/private/tmp/aipulse-processing-qa/AIPulseProcessingQA.app` had its widget removed and CloudKit disabled, then was locally ad-hoc signed with App Sandbox, user-selected read-only and app-scope-bookmark entitlements. The dashboard, LogWatcher, parser, SQLite, cache/notification and snapshot implementations were the production versions. Temporary home/menu/audit changes were restored byte-for-byte before the final normal build and are excluded from Git.

Input generation: create `.codex/sessions/2026/10/23` in a disposable fixture home. Add 6,000 small JSONL files containing only `session_meta`. Add `rollout-zz-processing.jsonl` with a `session_meta` (`session_id=processing-resume`, `model=gpt-5-codex`) and 80,000 `token_count` records. Give records distinct ISO-8601 timestamps increasing one millisecond from ten minutes before generation; `payload.last_token_usage` contains `input_tokens=2`, `output_tokens=1`. Stop the app and append 50,000 records continuing that sequence. This simulates offline growth with persisted checkpoints; it is not a multi-day soak.

| Scenario | Actual result |
| --- | --- |
| Initial discovery and history parsing | Forehead showed `正在读取本地数据…`, then `正在解析活动日志…`. |
| Queue another scan during parsing | Busy state persisted until both scans and data publication finished. |
| Initial completion | 80,000 rows / 240,000 tokens; actual dashboard restored the activity wave. |
| Restart and append while stopped | Nonzero checkpoint retained. RuntimeQA intentionally skips normal startup bookmark restoration, so its synthetic folder was explicitly granted again before the warm scan. |
| Warm scan, cold-import flag false throughout | Actual forehead audit: reading → parsing → reading remaining sources → preparing → wave. No nil/idle forehead occurred between the first busy state and completion. Preparation lasted about two seconds in this sample, not a benchmark. |
| Switch Today to Week during warm parsing | Parsing remained visible while the older snapshot stayed available. |
| Warm completion | 130,000 rows / 130,000 distinct dedupe keys / 390,000 tokens; complete persisted byte offset and SQLite `quick_check=ok`; dashboard showed 390.0K and the wave. |
| Hold a controlled preparation handle, close/reopen dashboard | Preparation persisted; this deliberate lifetime probe is separate from the real warm-read result. |
| Inject a local read failure while preparation is held | `本地活动读取失败` replaced processing text. |
| Inject a permission issue while both remain | Actual-target authorization text/action took priority. This verifies UI precedence, not a new OS-denial scenario. |
| Clear injected issues, keep preparation | Preparation returned. |
| Release the last handle | Wave returned; message/stage recorded nil at completion. |

The RuntimeQA collectors remain disabled, so the ordinary 120-second freshness rule can later replace the wave with an out-of-date message; this is not a stuck processing handle. The completion check uses the recorded completion time, rather than assuming the wave persists indefinitely.

Foundation persisted `/tmp` paths although input generation used `/private/tmp`. An initial checkpoint query using the alias was corrected to the persisted path before append. Final verification checked that canonical checkpoint against the entire input size.

Initial JSONL SHA-256: `4f28df7a80350dc161b7fb502b6b26f5a14e5afbc46862f658393a9fffcb5675`. After append: `759d05e12b04b153921b792fd59b50f6be910f97376238dfc232598b3872b19e`. Initial checkpoint: 11,040,097 bytes; final checkpoint: 17,940,097 bytes.

## Scope and cleanup

Verified actual Codex filesystem → parser → SQLite → notification/cache → dashboard processing, warm resume, range switching, UI lifetime and issue priority. The five pre-implementation checks cover overlapping completion/cancellation ownership. No private production logs, account/cloud behavior, external-volume unplug/remount, multi-day runtime or iOS/watchOS acceptance is claimed. Other log formats and Git/repository work have compilation/existing regression coverage, rather than new per-source UI acceptance.

Cleanup completed: stopped/unregistered the exact temporary QA and build apps; removed newly created sandbox Data, fixtures, the five temporary checks, source backups/instrumentation, builds and logs; restored the exact pre-task Git exclude bytes. OS-managed container metadata outside Data was left to macOS. Only this report is retained as verification material.
