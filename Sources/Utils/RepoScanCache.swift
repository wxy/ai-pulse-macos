import Foundation

/// One git repository found by a scan.
struct CachedRepo: Codable, Equatable {
    let path: String            // absolute path
    let name: String            // lastPathComponent
    let hasAiderMarkers: Bool   // contains .aider.chat.history.md / .aider.llm.history
}

/// Scan result for one directory.
struct CachedDirScan: Codable, Equatable {
    let dirPath: String
    let repos: [CachedRepo]
    let scannedAt: Date
    var truncated: Bool = false   // deadline hit → result incomplete
}

/// Shared, persisted repository-scan cache — the single source of truth for
/// repo counts/lists across Onboarding, Settings, and aider detection.
///
/// Thread-safe: the internal dict is guarded by `lock` (scans run on background
/// threads and `cachedScan` may be called from tests off-main). UI observes via
/// `NotificationCenter` on `didChange`, matching the existing `.dataDidChange`
/// pattern in this codebase.
///
/// Every member is explicitly `nonisolated` so the cache is callable from any
/// isolation in both build configurations: the Xcode target compiles with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (unannotated types become
/// MainActor), while the SwiftPM build defaults to nonisolated. Marking members
/// `nonisolated` keeps the semantics identical in both.
nonisolated final class RepoScanCache: @unchecked Sendable {
    nonisolated static let shared = RepoScanCache()
    nonisolated static let ttl: TimeInterval = 300            // 5 min; older scans are "missing"
    nonisolated static let scanBudget: TimeInterval = 2.0      // soft budget per directory
    nonisolated static let storeKey = "repo_scan_cache"
    nonisolated static let didChange = Notification.Name("RepoScanCacheDidChange")

    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var _scans: [String: CachedDirScan] = [:]
    /// `nonisolated(unsafe)`: `UserDefaults` is not Sendable in the SDK, but is
    /// thread-safe in practice (all reads/writes are synchronized internally).
    private nonisolated(unsafe) let store: UserDefaults

    nonisolated init(store: UserDefaults = .standard) {
        self.store = store
        _scans = Self.load(from: store)
    }

    /// Thread-safe snapshot of all cached scans.
    nonisolated var scans: [String: CachedDirScan] {
        lock.lock(); defer { lock.unlock() }
        return _scans
    }

    /// Fresh scan for `dir`, or nil if missing/stale.
    nonisolated func cachedScan(for dir: String) -> CachedDirScan? {
        let key = Self.expand(dir)
        lock.lock(); defer { lock.unlock() }
        guard let s = _scans[key],
              Date().timeIntervalSince(s.scannedAt) < Self.ttl else { return nil }
        return s
    }

    /// Run a fast background scan of `dir`, collecting repos + aider markers in
    /// one pass, then store + persist + notify. Progress is published live as
    /// each repo is found so the UI can show a running count instead of an
    /// indefinite spinner. No-op if the dir isn't readable.
    nonisolated func scan(dir: String) async {
        let expanded = Self.expand(dir)
        let scanStart = Date()
        guard FileManager.default.fileExists(atPath: expanded) else {
            Logger.warning("RepoScanCache: scan skipped (not readable): \(expanded)")
            return
        }
        Logger.info("RepoScanCache: scan start: \(expanded)")
        let deadline = Date().addingTimeInterval(Self.scanBudget)
        let result = await Task.detached(priority: .userInitiated) { () -> (repos: [CachedRepo], truncated: Bool) in
            let fm = FileManager.default
            let root = URL(fileURLWithPath: expanded, isDirectory: true)
            var repos: [CachedRepo] = []
            let truncated = GitRepoScanner.enumerate(in: root, deadline: deadline) { url in
                let hasAider = fm.fileExists(atPath: url.appendingPathComponent(".aider.chat.history.md").path)
                    || fm.fileExists(atPath: url.appendingPathComponent(".aider.llm.history").path)
                let repo = CachedRepo(path: url.path, name: url.lastPathComponent, hasAiderMarkers: hasAider)
                repos.append(repo)
                // Live progress: publish the running count so the UI updates.
                self.publishPartial(repos: repos, for: expanded)
            }
            return (repos, truncated)
        }.value
        let sorted = result.repos.sorted { $0.name < $1.name }
        let scan = CachedDirScan(dirPath: expanded, repos: sorted,
                                 scannedAt: Date(), truncated: result.truncated)
        storeResult(scan, for: expanded)
        Logger.info("RepoScanCache: scanned \(expanded): \(result.repos.count) repos, "
                    + "truncated=\(result.truncated), "
                    + String(format: "%.2f", Date().timeIntervalSince(scanStart)) + "s")
    }

    /// Publish a partial scan result in-memory (no persist) so the UI can show
    /// a live repo count while the walk is still running. Marked `truncated`
    /// since it is incomplete; the final `storeResult` replaces it. Runs on the
    /// walker's background thread, so the notification hops to main.
    private nonisolated func publishPartial(repos: [CachedRepo], for key: String) {
        lock.lock()
        _scans[key] = CachedDirScan(dirPath: key, repos: repos,
                                    scannedAt: Date(), truncated: true)
        lock.unlock()
        postDidChange()
    }

    nonisolated func invalidate(dir: String) {
        let key = Self.expand(dir)
        lock.lock()
        _scans.removeValue(forKey: key)
        lock.unlock()
        persist()
        postDidChange()
    }

    /// Total repos across `dirs`, using only fresh cache entries.
    nonisolated func totalRepos(in dirs: [String]) -> Int {
        dirs.reduce(0) { $0 + (cachedScan(for: $1)?.repos.count ?? 0) }
    }

    // MARK: - Internal

    private nonisolated func storeResult(_ scan: CachedDirScan, for key: String) {
        lock.lock()
        _scans[key] = scan
        lock.unlock()
        persist()
        postDidChange()
    }

    /// Post `didChange` on the main thread. SwiftUI's `onReceive` asserts when a
    /// notification it observes is delivered on a background thread, and the
    /// scan walk runs inside `Task.detached` — so every post hops to main.
    private nonisolated func postDidChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }

    private nonisolated func persist() {
        lock.lock()
        let snapshot = _scans
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            store.set(data, forKey: Self.storeKey)
        }
    }

    private nonisolated static func expand(_ p: String) -> String {
        NSString(string: p).expandingTildeInPath
    }

    private nonisolated static func load(from store: UserDefaults) -> [String: CachedDirScan] {
        guard let data = store.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: CachedDirScan].self, from: data)
        else { return [:] }
        return dict
    }
}
