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
final class RepoScanCache: @unchecked Sendable {
    static let shared = RepoScanCache()
    static let ttl: TimeInterval = 300            // 5 min; older scans are "missing"
    static let scanBudget: TimeInterval = 2.0      // soft budget per directory
    static let storeKey = "repo_scan_cache"
    static let didChange = Notification.Name("RepoScanCacheDidChange")

    private let lock = NSLock()
    private var _scans: [String: CachedDirScan] = [:]
    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        _scans = Self.load(from: store)
    }

    /// Thread-safe snapshot of all cached scans.
    var scans: [String: CachedDirScan] {
        lock.lock(); defer { lock.unlock() }
        return _scans
    }

    /// Fresh scan for `dir`, or nil if missing/stale.
    func cachedScan(for dir: String) -> CachedDirScan? {
        let key = Self.expand(dir)
        lock.lock(); defer { lock.unlock() }
        guard let s = _scans[key],
              Date().timeIntervalSince(s.scannedAt) < Self.ttl else { return nil }
        return s
    }

    /// Run a fast background scan of `dir`, collecting repos + aider markers in
    /// one pass, then store + persist + notify. No-op if the dir isn't readable.
    func scan(dir: String) async {
        let expanded = Self.expand(dir)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        let deadline = Date().addingTimeInterval(Self.scanBudget)
        let result = await Task.detached(priority: .userInitiated) { () -> (repos: [CachedRepo], truncated: Bool) in
            let fm = FileManager.default
            let root = URL(fileURLWithPath: expanded, isDirectory: true)
            var repos: [CachedRepo] = []
            let truncated = GitRepoScanner.enumerate(in: root, deadline: deadline) { url in
                let hasAider = fm.fileExists(atPath: url.appendingPathComponent(".aider.chat.history.md").path)
                    || fm.fileExists(atPath: url.appendingPathComponent(".aider.llm.history").path)
                repos.append(CachedRepo(path: url.path, name: url.lastPathComponent, hasAiderMarkers: hasAider))
            }
            return (repos, truncated)
        }.value
        let sorted = result.repos.sorted { $0.name < $1.name }
        let scan = CachedDirScan(dirPath: expanded, repos: sorted,
                                 scannedAt: Date(), truncated: result.truncated)
        storeResult(scan, for: expanded)
    }

    func invalidate(dir: String) {
        let key = Self.expand(dir)
        lock.lock()
        _scans.removeValue(forKey: key)
        lock.unlock()
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Total repos across `dirs`, using only fresh cache entries.
    func totalRepos(in dirs: [String]) -> Int {
        dirs.reduce(0) { $0 + (cachedScan(for: $1)?.repos.count ?? 0) }
    }

    // MARK: - Internal

    private func storeResult(_ scan: CachedDirScan, for key: String) {
        lock.lock()
        _scans[key] = scan
        lock.unlock()
        persist()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func persist() {
        lock.lock()
        let snapshot = _scans
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            store.set(data, forKey: Self.storeKey)
        }
    }

    private static func expand(_ p: String) -> String {
        NSString(string: p).expandingTildeInPath
    }

    private static func load(from store: UserDefaults) -> [String: CachedDirScan] {
        guard let data = store.data(forKey: storeKey),
              let dict = try? JSONDecoder().decode([String: CachedDirScan].self, from: data)
        else { return [:] }
        return dict
    }
}
