# Chart NaN Defense and Diagnostic Journal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make dashboard chart rendering safe against non-finite geometry inputs and add a bounded JSONL diagnostic journal for post-crash reconstruction.

**Architecture:** Add one pure `ChartMath` boundary that converts every trend-axis, progress, scale, and bar value to finite, non-negative numbers before SwiftUI Charts sees it. Add an independent serial-queue `DiagnosticJournal` that writes one JSON object per behavioral event to an active file, rotates and zlib-compresses archives, and enforces a size budget. Then instrument only lifecycle, refresh, cache, API, and dashboard apply/render boundaries—not hover or frame events.

**Tech Stack:** Swift 6, SwiftUI Charts, Compression (`COMPRESSION_ZLIB`), Foundation `FileHandle`, XCTest.

**Spec:** None. The production crash reports, register evidence (`NaN` and `Int64` conversion boundary), and repository inspection are the authority.

## Global Constraints

- macOS minimum remains `.v14`; Swift tools version remains 6.0.
- Do not add third-party dependencies.
- Keep the journal independent from `Sources/Utils/Logger.swift`.
- Active journal file: `events-active.jsonl`; archives: `events-YYYYMMDD-HHMMSS-<UUID>.jsonl.zlib`.
- Rotation threshold: 256 KiB active file or 2,000 active lines.
- Archive budget: 4 MiB compressed; compression failure keeps the plain JSONL file and counts it against the budget.
- Journal events must never emit NaN or infinity as a JSON number; convert them to JSON `null`.
- Do not record API keys, authorization headers, request bodies, prompts, file-path originals, or user content.
- Record state changes and boundaries only; never record continuous hover, scroll, layout, or per-frame events.
- Every task must pass `swift build` and `make test`; no UI screenshot verification.
- Keep edits tightly scoped; no unrelated refactoring.

---

### Task 1: Finite chart boundary

**Files:**

- Create: `Sources/Utils/ChartMath.swift`
- Modify: `Sources/UI/Dashboard/DashboardView.swift`
- Modify: `Sources/UI/Dashboard/ToolDetailOverlayView.swift`
- Test: `Tests/ChartMathTests.swift`

**Interfaces:**

- Produces `ChartMath.finite(Double, fallback: Double) -> Double`.
- Produces `ChartMath.progress(Double) -> Double`, returning `0.0...1.0`.
- Produces `ChartMath.barValue(base:progress:scale:) -> Double`, returning a finite non-negative value.
- Produces `ChartMath.axisMax(Double, fallback: Double) -> Double`, returning a finite positive value.
- Produces `ChartMath.tokenAxisMax(context:window:) -> Int`, returning at least `1`.

- [ ] **Step 1: Write failing pure-function tests**

Create `Tests/ChartMathTests.swift` with cases for `NaN`, `+infinity`, `-infinity`, negative spend, progress above `1`, empty-axis fallback, zero division, and a token window smaller than context. Assert exact fallback values and `value.isFinite`.

- [ ] **Step 2: Run the focused test**

Run: `swift test --filter ChartMathTests`

Expected: compilation fails because `ChartMath` does not exist.

- [ ] **Step 3: Implement the finite boundary**

Create `Sources/Utils/ChartMath.swift` as a `nonisolated enum` with pure static functions. NaN, infinity, and negative values fall back before multiplication; division inputs are positive; progress is clamped to `0...1`; axis maxima are finite and positive. Do not introduce a view-model type in this task.

- [ ] **Step 4: Route dashboard trend values through the boundary**

In `DashboardView.swift`, sanitize `trendSpendAxis`, `trendCodeAxis`, `subDaily`, `prog`, and all four `BarMark` y-values. Change the chart-level `.animation(..., value: barProgress)` to no chart-level data animation; retain the existing progress-driven entry animation. Add `.id(timeRange)` to the `Chart` so switching identity does not reuse the old chart tree. Keep tooltips and axes unchanged except for finite values.

- [ ] **Step 5: Route token-chart values through the boundary**

In `ToolDetailOverlayView.contextChart`, replace raw `yMax` calculation with `ChartMath.tokenAxisMax(context: maxContext, window: trend.windowTokens)`. Do not alter mark semantics or interaction.

- [ ] **Step 6: Verify**

Run: `swift test --filter ChartMathTests && swift build && make test`

Expected: focused tests and full suite pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/Utils/ChartMath.swift Tests/ChartMathTests.swift Sources/UI/Dashboard/DashboardView.swift Sources/UI/Dashboard/ToolDetailOverlayView.swift
git commit -m "fix: sanitize dashboard chart geometry"
```

### Task 2: Bounded JSONL journal core

**Files:**

- Create: `Sources/Utils/DiagnosticJournal.swift`
- Test: `Tests/DiagnosticJournalTests.swift`

**Interfaces:**

- Produces `enum DiagnosticValue: Sendable` with `string`, `bool`, `int`, `double`, `date`, `array`, and `object` cases.
- Produces `static func DiagnosticJournal.log(_ name: String, _ data: [String: DiagnosticValue])`.
- Produces test-only `DiagnosticJournal(directory:activeByteLimit:activeLineLimit:archiveByteLimit:)` plus `flushForTesting()`.
- Produces test-only `activeFileURL` and `archiveURLs` for assertions.

- [ ] **Step 1: Write failing core tests**

Create `Tests/DiagnosticJournalTests.swift` using a unique temporary directory. Assert: valid JSONL round trip; session and monotonic sequence; non-finite doubles become `null`; active rotation at 256 bytes; zlib archive is created and active is empty; exceeding a tiny archive budget deletes the oldest archive; no event contains API-key-like values by construction.

- [ ] **Step 2: Run the focused test**

Run: `swift test --filter DiagnosticJournalTests`

Expected: compilation fails because `DiagnosticJournal` does not exist.

- [ ] **Step 3: Implement serialization and writer**

Implement custom JSON serialization without `JSONEncoder` so malformed/non-finite values can be normalized safely. Escape strings and object keys; map non-finite doubles to `null`; format dates as ISO-8601 with fractional seconds. Each line includes `v`, `seq`, `ts`, `uptime`, `pid`, `session`, `app`, `os`, `event`, and `data`.

- [ ] **Step 4: Implement rotation and compression**

Write from a serial utility queue. Before append, rotate when adding the line would exceed the byte limit or the line count reaches 2,000. Close and rename the active file, zlib-compress it with `compression_encode_buffer`, then delete the temporary plain file on success or retain it on failure. Sort archives oldest-first and remove them until total size is within the archive budget. In production, store files under `Application Support/AIPulse/diagnostics`.

- [ ] **Step 5: Verify**

Run: `swift test --filter DiagnosticJournalTests && swift build && make test`

Expected: focused tests and full suite pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Utils/DiagnosticJournal.swift Tests/DiagnosticJournalTests.swift
git commit -m "feat: add bounded diagnostic jsonl journal"
```

### Task 3: Instrument crash-relevant behavior

**Files:**

- Modify: `Sources/App/AIPulseApp.swift`
- Modify: `Sources/Engine/DataRefreshCoordinator.swift`
- Modify: `Sources/Ingest/ApiPoller.swift`
- Modify: `Sources/Store/DashboardCache.swift`
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

**Interfaces:**

- Consumes `DiagnosticJournal.log(_:_)` from Task 2.
- Records stable event names: `app_launch`, `sleep`, `wake`, `range_change`, `dashboard_load`, `apply_snapshot`, `chart_render`, `cache_read`, `cache_write`, `cache_invalidate`, `api_balance`, and `api_error`.

- [ ] **Step 1: Add lifecycle and refresh events**

At successful app launch, log `app_launch` with integrations count. In the coordinator sleep/wake paths, log `sleep` and `wake`. In `notifyPhaseBalance`, log `cache_invalidate` with `reason=balance_snapshot`. Do not change scheduling behavior.

- [ ] **Step 2: Add API and cache boundary events**

In `ApiPoller.cacheBalance`, log provider id, entry count, finite balance values, previous balance only when present, and fetch result. In `cacheError`, log provider id and sanitized HTTP/parse result. In `DashboardCache.read/write/invalidateAll`, log the range, outcome, age when known, and error description when present. Never log credentials.

- [ ] **Step 3: Add dashboard apply/render breadcrumbs**

Log `range_change` only in `onChange(of: timeRange)`. In `applySnapshot`, log requested/loaded ranges, daily/code/balance counts, progress, and whether every daily value is finite. In `trendSection`, log one boundary event when data becomes ready; include range, point count, axis maxima, progress, and all-finite status. Do not log hover updates.

- [ ] **Step 4: Verify**

Run: `swift build && make test`

Expected: build and full suite pass; no diagnostics are emitted from hover or per-frame paths.

- [ ] **Step 5: Commit**

```bash
git add Sources/App/AIPulseApp.swift Sources/Engine/DataRefreshCoordinator.swift Sources/Ingest/ApiPoller.swift Sources/Store/DashboardCache.swift Sources/UI/Dashboard/DashboardView.swift
git commit -m "feat: journal chart and refresh diagnostics"
```
