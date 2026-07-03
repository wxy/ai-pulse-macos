# Data Coordination & UX Feedback — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace scattered independent timers with a centralized `DataRefreshCoordinator` that manages all data ingestion phases, detects changes with debounce, and notifies UI consumers uniformly. Add new repo discovery, settings cache, sound feedback, and Dock icon pulse.

**Architecture:** `DataRefreshCoordinator` (new singleton) orchestrates three ingestion phases (30s / 5min / 1h). Each phase completes → change detection → 500ms debounce → `.dataDidChange` notification. All UI consumers (MenuBar, Dashboard, Dock) listen to this single notification. `RepoDiscovery` (new) runs in Phase 1 to find un-watched repos. `CoinSound` triggers on every data change. `DockManager` adds scale-pulse animation.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, GRDB

## Global Constraints

- macOS 14+ deployment target
- No database schema changes
- No new dependencies
- Existing IntegrationRegistry / LogWatcher / ApiPoller interfaces unchanged
- Swift concurrency: use `Task { @MainActor in }` for UI updates, serial queue for coordinator state

---

## File Structure

| File | Operation | Responsibility |
|------|-----------|---------------|
| `Sources/Engine/DataRefreshCoordinator.swift` | **Create** | Centralized 3-phase scheduler, change detection, debounce, notification |
| `Sources/Engine/RepoDiscovery.swift` | **Create** | Scan configured directories for new git repos |
| `Sources/App/AIPulseApp.swift` | Modify | Replace individual Timers with `DataRefreshCoordinator.shared.start()` |
| `Sources/UI/MenuBar/MenuBarController.swift` | Modify | Remove internal Timer; listen to `.dataDidChange` |
| `Sources/UI/Dock/DockManager.swift` | Modify | Remove internal Timer; listen to `.dataDidChange`; add `pulseIcon()` |
| `Sources/UI/Dashboard/DashboardView.swift` | Modify | Listen to `.dataDidChange` in addition to existing triggers |
| `Sources/UI/Settings/SettingsView.swift` | Modify | Add in-memory scan cache to `ReposTab` |
| `Sources/GitMonitor/GitMonitor.swift` | Modify | Expose read-only `watchedRepos` for RepoDiscovery |
| `Sources/Engine/CoinSound.swift` | Modify | Accept trigger from Coordinator; support bundled audio file |
| `Resources/coin.wav` | **Create** | Coin sound audio file (optional — NSSound.beep as fallback) |

---

### Task 1: DataRefreshCoordinator — Core Scheduler

**Files:**
- Create: `Sources/Engine/DataRefreshCoordinator.swift`

**Interfaces:**
- Produces: `DataRefreshCoordinator.shared`, `func start()`, `func stop()`, `func notifyDataChange()` (for external triggers like Settings add-directory)
- Posts: `Notification.Name.dataDidChange`

- [ ] **Step 1: Create DataRefreshCoordinator.swift**

```swift
import Foundation

extension Notification.Name {
    /// Posted when new data has been ingested (logs, commits, or balance snapshots).
    /// UI consumers (MenuBar, Dashboard, Dock) should refresh in response.
    static let dataDidChange = Notification.Name("AIPulseDataDidChange")
}

/// Centralized scheduler that replaces scattered independent timers.
///
/// Three ingestion phases run at staggered intervals:
/// - Phase 1 (30s): LogWatcher incremental scan + RepoDiscovery
/// - Phase 2 (5min): GitMonitor commit polling
/// - Phase 3 (1h): ApiPoller balance fetching
///
/// After any phase detects changes, a 500ms debounce window coalesces
/// rapid-fire writes before posting `.dataDidChange` to notify all UI consumers.
final class DataRefreshCoordinator {
    static let shared = DataRefreshCoordinator()

    enum Phase {
        case ingest, gitScan, balance
    }

    private var phase1Timer: DispatchSourceTimer?
    private var phase2Timer: DispatchSourceTimer?
    private var phase3Timer: DispatchSourceTimer?
    private var pendingNotifyWorkItem: DispatchWorkItem?
    private let notifyQueue = DispatchQueue(label: "com.wxy.aipulse.coordinator", qos: .utility)
    private var hasPendingChange = false

    private init() {}

    // MARK: - Public

    func start() {
        // Phase 1: Ingest (30s, first after 5s)
        phase1Timer = makeTimer(interval: .seconds(30), firstDeadline: .now() + 5) { [weak self] in
            self?.runPhase1()
        }

        // Phase 2: Git scan (5min, first after 15s)
        phase2Timer = makeTimer(interval: .seconds(300), firstDeadline: .now() + 15) { [weak self] in
            self?.runPhase2()
        }

        // Phase 3: Balance poll (1h, first after 10s)
        phase3Timer = makeTimer(interval: .seconds(3600), firstDeadline: .now() + 10) { [weak self] in
            self?.runPhase3()
        }

        diagLog("DataRefreshCoordinator: started (P1=30s, P2=5min, P3=1h)")
    }

    func stop() {
        phase1Timer?.cancel(); phase1Timer = nil
        phase2Timer?.cancel(); phase2Timer = nil
        phase3Timer?.cancel(); phase3Timer = nil
        pendingNotifyWorkItem?.cancel(); pendingNotifyWorkItem = nil
        diagLog("DataRefreshCoordinator: stopped")
    }

    /// Called by external triggers (e.g., Settings adds a new directory)
    /// to force an immediate ingest scan.
    func triggerIngest() {
        notifyQueue.async { [weak self] in
            self?.runPhase1()
        }
    }

    /// External callers can explicitly notify consumers (e.g., after
    /// on-demand polling by ApiPoller.fetchNow).
    func notifyDataChange() {
        notifyQueue.async { [weak self] in
            self?.scheduleUINotify()
        }
    }

    // MARK: - Phase runners

    private func runPhase1() {
        let countBefore = countUsageEvents()
        LogWatcher.shared.scan()
        let discovered = RepoDiscovery.scan()
        if discovered > 0 {
            diagLog("RepoDiscovery: found \(discovered) new repo(s)")
        }
        let countAfter = countUsageEvents()
        let changed = countAfter > countBefore || discovered > 0
        phaseDidComplete(.ingest, changesDetected: changed)
    }

    private func runPhase2() {
        let countBefore = countCodeChanges()
        GitMonitor.shared.poll()
        let countAfter = countCodeChanges()
        phaseDidComplete(.gitScan, changesDetected: countAfter > countBefore)
    }

    private func runPhase3() {
        let countBefore = countBalanceSnapshots()
        // ApiPoller.pollAll() is synchronous-dispatch (fires URLSession tasks);
        // balance snapshots are written async. We wait a short grace period
        // then check for changes.
        ApiPoller.shared.pollAll()
        notifyQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            let countAfter = self.countBalanceSnapshots()
            self.phaseDidComplete(.balance, changesDetected: countAfter > countBefore)
        }
    }

    // MARK: - Change detection

    private func phaseDidComplete(_ phase: Phase, changesDetected: Bool) {
        guard changesDetected else { return }
        diagLog("DataRefreshCoordinator: phase \(phase) detected changes")
        scheduleUINotify()
    }

    private func scheduleUINotify() {
        pendingNotifyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.notifyConsumers()
        }
        pendingNotifyWorkItem = workItem
        notifyQueue.asyncAfter(deadline: .now() + .milliseconds(500), execute: workItem)
    }

    private func notifyConsumers() {
        diagLog("DataRefreshCoordinator: posting .dataDidChange")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dataDidChange, object: nil)
            CoinSound.playForDataChange()
        }
    }

    // MARK: - Row counters (lightweight change detection)

    private func countUsageEvents() -> Int {
        // Synchronous read on the DB queue for quick comparison.
        // Using a semaphore to bridge async GRDB → sync check.
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage_event") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    private func countCodeChanges() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM code_change") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    private func countBalanceSnapshots() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = 0
        Task {
            do {
                count = try await AppDatabase.shared.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM balance_snapshot") ?? 0
                }
            } catch { }
            sem.signal()
        }
        sem.wait()
        return count
    }

    // MARK: - Timer factory

    private func makeTimer(interval: DispatchTimeInterval,
                           firstDeadline: DispatchTime,
                           handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: notifyQueue)
        timer.schedule(deadline: firstDeadline, repeating: interval)
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }
}
```

- [ ] **Step 2: Verify file compiles**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -30
```

Expected: Build succeeds (Task 1 introduces new types referenced by later tasks, but `LogWatcher.scan()` and `RepoDiscovery.scan()` don't exist yet — expect compile errors for those two calls). We'll resolve them in Tasks 2 and 3.

---

### Task 2: RepoDiscovery — New Repository Scanner

**Files:**
- Create: `Sources/Engine/RepoDiscovery.swift`
- Modify: `Sources/GitMonitor/GitMonitor.swift` — expose `watchedRepos`

**Interfaces:**
- Consumes: `GitMonitor.shared.watchedRepos` (Set<String>), `UserDefaults.stringArray(forKey: "repo_search_dirs")`
- Produces: `RepoDiscovery.scan() -> Int`

- [ ] **Step 1: Expose watchedRepos in GitMonitor**

Read [GitMonitor.swift](Sources/GitMonitor/GitMonitor.swift) around line 20, add a read-only accessor:

```swift
// In GitMonitor class body, after `private var lastSeenCommit`:

/// Read-only snapshot of currently watched repo paths.
/// Used by RepoDiscovery to diff against the filesystem.
var watchedRepoPaths: Set<String> {
    lock.lock(); defer { lock.unlock() }
    return watchedRepos
}
```

- [ ] **Step 2: Create Sources/Engine/RepoDiscovery.swift**

```swift
import Foundation

/// Scans configured directories for git repositories that are not yet
/// watched by GitMonitor, and registers them automatically.
enum RepoDiscovery {

    /// Scan `repo_search_dirs` for new git repos.
    /// - Returns: Number of newly discovered (and registered) repos.
    @discardableResult
    static func scan() -> Int {
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        let known = GitMonitor.shared.watchedRepoPaths
        var found = 0

        for dir in dirs {
            let expanded = NSString(string: dir).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else { continue }
            found += scanDirectory(URL(fileURLWithPath: expanded), known: known)
        }
        return found
    }

    // MARK: - Private

    private static func scanDirectory(_ dir: URL, known: Set<String>) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            let gitDir = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: gitDir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }

            if !known.contains(url.path) {
                GitMonitor.shared.watch(repoPath: url.path)
                diagLog("RepoDiscovery: new repo → \(url.path)")
                count += 1
            }
            enumerator.skipDescendants() // don't recurse into repo subdirectories
        }
        return count
    }
}
```

- [ ] **Step 3: Add LogWatcher.scan() public method**

Read [LogWatcher.swift](Sources/Ingest/LogWatcher.swift). The existing `start()` method runs on `scanQueue`. Add a public `scan()` method that other components can call without the FSEvent setup:

```swift
// In LogWatcher class body, add after start():

/// Perform an incremental scan without setting up FSEvent watchers.
/// Safe to call repeatedly; idempotent. Used by DataRefreshCoordinator.
func scan() {
    scanQueue.async { [weak self] in
        self?.scanClaudeProjectsOnly()
        self?.discoverAndWatchRepos()
    }
}
```

The `scanClaudeProjectsOnly()` method needs to be a variant of `watchClaudeCode()` that only does the scan (no FSEvent registration):

```swift
// Add as a private method:
private func scanClaudeProjectsOnly() {
    let dir = FileManager.default.realHomeDirectory
        .appendingPathComponent(".claude/projects")
    guard FileManager.default.fileExists(atPath: dir.path) else { return }
    scanClaudeCode(at: dir)
}
```

- [ ] **Step 4: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -30
```

Expected: Build succeeds (all new symbols defined).

---

### Task 3: AppDelegate — Wire Coordinator

**Files:**
- Modify: `Sources/App/AIPulseApp.swift`

**Interfaces:**
- Consumes: `DataRefreshCoordinator.shared`

- [ ] **Step 1: Replace individual timers with Coordinator**

Read [AIPulseApp.swift](Sources/App/AIPulseApp.swift). In `applicationDidFinishLaunching`, replace the scattered Timer/setup calls (lines 86-95) with the Coordinator.

Remove these lines (86-95):
```swift
// Poll watched git repos for new commits every 5 minutes
DispatchQueue.global(qos: .utility).async { GitMonitor.shared.poll() }
Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
    DispatchQueue.global(qos: .utility).async { GitMonitor.shared.poll() }
}

// Check for anomalies after each poll cycle
Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
    Task { await AnomalyDetector.shared.check() }
}
```

Replace with:
```swift
// Centralized data refresh coordinator (replaces scattered timers)
DataRefreshCoordinator.shared.start()

// Check for anomalies periodically (separate from data refresh — longer cycle)
Timer.scheduledTimer(withTimeInterval: 3660, repeats: true) { _ in
    Task { await AnomalyDetector.shared.check() }
}
```

Also update the `applicationWillTerminate` method to stop the coordinator:

```swift
func applicationWillTerminate(_ notification: Notification) {
    DataRefreshCoordinator.shared.stop()
    IntegrationRegistry.stopAll()
    DockManager.shared.stop()
    BookmarkManager.stopAll(securityScopedURLs)
    GitRepo.teardown()
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 4: MenuBarController — Respond to Notification

**Files:**
- Modify: `Sources/UI/MenuBar/MenuBarController.swift`

**Interfaces:**
- Consumes: `Notification.Name.dataDidChange`

- [ ] **Step 1: Remove internal Timer, add notification observer**

Read [MenuBarController.swift](Sources/UI/MenuBar/MenuBarController.swift). In `start()` (line 19), replace the Timer:

Remove:
```swift
timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refreshStats() }
```

Replace with:
```swift
// Observe data-change notifications from the centralized coordinator
NotificationCenter.default.addObserver(
    self, selector: #selector(onDataChanged),
    name: .dataDidChange, object: nil
)
```

Add the handler method:
```swift
@objc private func onDataChanged() {
    refreshStats()
}
```

The initial `refreshStats()` call at the end of `start()` remains — it does the first load.

- [ ] **Step 2: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 5: DockManager — Respond to Notification + Pulse Animation

**Files:**
- Modify: `Sources/UI/Dock/DockManager.swift`

**Interfaces:**
- Consumes: `Notification.Name.dataDidChange`

- [ ] **Step 1: Remove internal Timer, add notification observer, add pulse**

Read [DockManager.swift](Sources/UI/Dock/DockManager.swift). In `start()` (line 15), replace the Timer:

Remove:
```swift
timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
    self?.refresh()
}
```

Replace with:
```swift
// Observe data-change notifications from the centralized coordinator
NotificationCenter.default.addObserver(
    forName: .dataDidChange, object: nil, queue: .main
) { [weak self] _ in
    self?.refresh()
    self?.pulseIcon()
}
```

Add a throttle to `pulseIcon()` to prevent rapid-fire animation (minimum 2s interval):

After the existing properties:
```swift
private var lastPulseTime: Date = .distantPast
```

Add the `pulseIcon()` method:
```swift
/// Animate the Dock icon with a brief scale pulse to signal new data.
/// Throttled to at most once every 2 seconds.
func pulseIcon() {
    let now = Date()
    guard now.timeIntervalSince(lastPulseTime) >= 2.0 else { return }
    lastPulseTime = now

    let tile = NSApp.dockTile
    // Attempt layer-backed pulse via contentView; fall back to icon swap.
    if let view = tile.contentView, view.wantsLayer || view.layer != nil {
        view.wantsLayer = true
        let anim = CAKeyframeAnimation(keyPath: "transform.scale")
        anim.values = [1.0, 1.15, 1.0]
        anim.keyTimes = [0, 0.5, 1.0]
        anim.duration = 0.3
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        view.layer?.add(anim, forKey: "pulse")
    }
    // NSDockTile.contentView is often nil for simple icon setups.
    // The badge label change + progress bar already give visual feedback.
    // Full pulse animation requires a custom NSView set as contentView,
    // which we defer to a follow-up (P3 polish).
    tile.display()
}
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 6: DashboardView — Update Notification

**Files:**
- Modify: `Sources/UI/Dashboard/DashboardView.swift`

**Interfaces:**
- Consumes: `Notification.Name.dataDidChange`

- [ ] **Step 1: Add .dataDidChange observer**

Read [DashboardView.swift](Sources/UI/Dashboard/DashboardView.swift). At line 85-87, the existing `.dashboardRefresh` observer. Add a second observer for `.dataDidChange`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .dashboardRefresh)) { _ in
    Task { await load() }
}
.onReceive(NotificationCenter.default.publisher(for: .dataDidChange)) { _ in
    Task { await load() }
}
```

Also update any code that posts `.dashboardRefresh` to also (or instead) post `.dataDidChange`. The key location is in `SettingsView.pickDir()` at the end where it posts `.dashboardRefresh` — we'll handle that in Task 7.

- [ ] **Step 2: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 7: SettingsView ReposTab — Memory Cache

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift`

**Interfaces:**
- Produces: `ReposTab` with in-memory scan cache

- [ ] **Step 1: Add static cache to ReposTab**

Read [SettingsView.swift](Sources/UI/Settings/SettingsView.swift) around line 359 (the `repoDirsKey` and `ReposTab` struct).

Add the cache right before the `repoDirsKey` line:

```swift
// In-memory cache for repo scans (avoids full filesystem enumeration
// every time the Repos tab is opened). Invalidated on directory add/remove.
private var repoScanCache: [String: (timestamp: Date, repos: [String])] = [:]
private let repoSscanCacheTTL: TimeInterval = 300 // 5 minutes
```

- [ ] **Step 2: Modify startScan() to use cache**

In `startScan()` (line 464), modify the logic so `scanOne()` is only called for cache misses. The method currently builds `dirEntries` then loops with `scanOne`. Change to check cache first:

Replace the Task block in `startScan()`:
```swift
Task {
    for i in dirEntries.indices {
        await scanOne(at: i)
    }
}
```

With:
```swift
Task {
    for i in dirEntries.indices {
        let path = dirEntries[i].path
        if let cached = repoScanCache[path],
           Date().timeIntervalSince(cached.timestamp) < repoSscanCacheTTL {
            // Cache hit — populate without filesystem scan
            await MainActor.run {
                guard i < dirEntries.count else { return }
                dirEntries[i].repoCount = cached.repos.count
                dirEntries[i].repos = cached.repos
                dirEntries[i].isScanning = false
            }
        } else {
            await scanOne(at: i)
        }
    }
}
```

- [ ] **Step 3: Write to cache after scan completes**

In `scanOne()` (line 509), after the `await MainActor.run` block that sets results (around line 532-537), add cache write:

```swift
await MainActor.run {
    guard idx < dirEntries.count else { return }
    dirEntries[idx].repoCount = foundRepos.count
    dirEntries[idx].repos = foundRepos
    dirEntries[idx].isScanning = false
    // Update cache
    repoScanCache[path] = (Date(), foundRepos)
}
```

- [ ] **Step 4: Invalidate cache on directory add/remove**

In `pickDir()` (line 486), after appending the entry and calling `scanOne`, the cache is handled automatically (scanOne writes to cache). No change needed.

In the delete alert handler (line 453-457), add cache invalidation:

```swift
Button(I18n.t("repos.remove"), role: .destructive) {
    if let d = deleteTarget {
        dirEntries.removeAll { $0.path == d }
        repoScanCache.removeValue(forKey: d)  // invalidate cache
        save()
    }
}
```

- [ ] **Step 5: Update .dashboardRefresh to .dataDidChange**

In `pickDir()`, at the end (line 503), change:
```swift
NotificationCenter.default.post(name: .dashboardRefresh, object: nil)
```
To:
```swift
DataRefreshCoordinator.shared.triggerIngest()
```

- [ ] **Step 6: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 8: CoinSound — Trigger on Data Change

**Files:**
- Modify: `Sources/Engine/CoinSound.swift`

**Interfaces:**
- Consumes: Called from `DataRefreshCoordinator.notifyConsumers()`
- Produces: `CoinSound.playForDataChange()`

- [ ] **Step 1: Add playForDataChange method**

Read [CoinSound.swift](Sources/Engine/CoinSound.swift). Add a new static method for data-change-triggered sound (alongside the existing `play(for:)` method):

```swift
/// Play a single coin sound when new data arrives.
/// Separate from `play(for:)` which scales by spend amount (used by ApiPoller).
static func playForDataChange() {
    guard UserDefaults.standard.bool(forKey: "coin_sound_enabled") else { return }
    // Try bundled audio file first, fall back to system beep
    if let url = Bundle.main.url(forResource: "coin", withExtension: "wav") {
        let sound = NSSound(contentsOf: url, byReference: false)
        sound?.play()
    } else {
        NSSound.beep()
    }
}
```

- [ ] **Step 2: Verify it's called from DataRefreshCoordinator**

Already done in Task 1 — `notifyConsumers()` calls `CoinSound.playForDataChange()`.

- [ ] **Step 3: Verify build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1 | head -20
```

Expected: Build succeeds.

---

### Task 9: Integration — Verify Full Build & Data Flow

**Files:**
- Modify: `Sources/UI/Settings/SettingsView.swift` (cleanup any remaining `.dashboardRefresh` references)
- Read: All modified files for consistency

**Interfaces:**
- Verifies: `DataRefreshCoordinator` → `.dataDidChange` → MenuBar + Dashboard + Dock

- [ ] **Step 1: Full build**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift build 2>&1
```

Expected: Build succeeds with zero errors.

- [ ] **Step 2: Run existing tests**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && swift test 2>&1
```

Expected: All existing tests pass.

- [ ] **Step 3: Manual verification checklist**

Build and run the app:
```bash
make run-app
```

Verify:
1. App launches without errors in console
2. Dock menu shows stats (MenuBar receiving `.dataDidChange`)
3. Dashboard opens and shows charts
4. Settings → Repos tab: open twice, second time no spinner (cache hit)
5. Console shows "DataRefreshCoordinator: phase ingest/gitScan detected changes" logs

- [ ] **Step 4: Check for any remaining `.dashboardRefresh` references**

```bash
cd /Users/xingyuwang/develop/ai-pulse-macos && grep -rn "dashboardRefresh" Sources/ --include="*.swift"
```

Expected: Should only remain in backward-compat locations (if any). The `OnboardingView` also posts `.dashboardRefresh` on finish — update it:

In [OnboardingView.swift](Sources/UI/Onboarding/OnboardingView.swift), find `NotificationCenter.default.post(name: .dashboardRefresh, object: nil)` and replace with:
```swift
NotificationCenter.default.post(name: .dataDidChange, object: nil)
```

---

### Task 10: Optional — Coin Sound Audio File

**Files:**
- Create: `Resources/coin.wav` (minimal placeholder)
- Note: A real audio file can be added later; NSSound.beep() fallback works immediately.

- [ ] **Step 1: Note on audio file**

The `CoinSound.playForDataChange()` method already has the fallback path:
```swift
if let url = Bundle.main.url(forResource: "coin", withExtension: "wav") {
    let sound = NSSound(contentsOf: url, byReference: false)
    sound?.play()
} else {
    NSSound.beep()
}
```

No placeholder file is created — the beep fallback is sufficient for now. A proper coin sound `.wav` file can be added to `Resources/` and the Xcode project later.

---

## Implementation Order

Tasks should be executed in this order (dependency chain):

```
Task 1 (Coordinator) ──┐
                       ├── Task 3 (AppDelegate)
Task 2 (RepoDiscovery)─┘
                       │
                       ├── Task 4 (MenuBar)
                       ├── Task 5 (DockManager)
                       ├── Task 6 (DashboardView)
                       ├── Task 7 (SettingsView cache)
                       └── Task 8 (CoinSound)
                                    │
                                    └── Task 9 (Integration verify)
                                             │
                                             └── Task 10 (Audio file, optional)
```

Tasks 4-8 are independent and can be done in any order after Tasks 1-3 complete.
