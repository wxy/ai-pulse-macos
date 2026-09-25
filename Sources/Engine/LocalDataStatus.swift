import Foundation

/// Permissions and source presence are independent of scanner completion and historical totals.
struct LocalDataStatus: Equatable {
    enum Access: Equatable { case notRequired, granted, missing, expired }
    enum Activity: Equatable { case needsAccess, accessExpired, scanning, noSources, noActivity, ready, stale, failed }
    enum Repositories: Equatable { case notConfigured, needsAccess, missing, ready }
    let homeAccess: Access
    let activity: Activity
    let repositories: Repositories

    static func resolve(homeAccess: Access, hasReadableLogs: Bool, scan: LogScanObservation.Status,
                        hasActivity: Bool?, rootsConfigured: Bool, rootsAccessible: Bool, rootsExist: Bool, priorReadUsable: Bool = false) -> Self {
        let activity: Activity
        if !hasReadableLogs && homeAccess == .missing { activity = .needsAccess }
        else if !hasReadableLogs && homeAccess == .expired { activity = .accessExpired }
        else if scan == .failed { activity = .failed }
        else if !hasReadableLogs { activity = .noSources }
        else if scan == .inactive || (scan == .scanning && !priorReadUsable) { activity = .scanning }
        else if scan == .stale { activity = .stale }
        else { activity = hasActivity == false ? .noActivity : .ready }
        let repositories: Repositories = !rootsConfigured ? .notConfigured
            : !rootsAccessible ? .needsAccess : !rootsExist ? .missing : .ready
        return Self(homeAccess: homeAccess, activity: activity, repositories: repositories)
    }

    var canReportCurrentActivity: Bool { activity == .ready || activity == .noActivity }

    static var logPaths: [String] {
        [".claude/projects", ".codex/sessions", ".dsh/sessions", ".qwen/projects",
         ".local/share/opencode/storage/message",
         "Library/Application Support/Code/User/workspaceStorage",
         "Library/Application Support/Code/User/globalStorage/emptyWindowChatSessions",
         "Library/Application Support/Code - Insiders/User/workspaceStorage",
         "Library/Application Support/Code - Insiders/User/globalStorage/emptyWindowChatSessions"]
            .map { FileManager.default.realHomeDirectory.appendingPathComponent($0).path }
    }
}

enum LocalDataStatusCache {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var cached: (hasActivity: Bool?, status: LocalDataStatus, at: Date)?
    private static let ttl: TimeInterval = 10

    /// Drop the memoized status so the next `current(hasActivity:)` re-probes
    /// the filesystem immediately instead of waiting out the TTL.
    static func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }

    /// Memoized accessor. The probe stats 9 log paths plus every cached repo
    /// under configured roots — too costly to run on the main thread for
    /// every notification burst (menu bar apply, dashboard ticks, settings
    /// refresh). Fresh probe on TTL expiry or explicit invalidation from the
    /// scan/bookmark notifications that change its inputs.
    static func current(hasActivity: Bool?) -> LocalDataStatus {
        _ = observers
        lock.lock()
        if let cached, cached.hasActivity == hasActivity,
           Date().timeIntervalSince(cached.at) < ttl {
            lock.unlock()
            return cached.status
        }
        lock.unlock()
        let status = LocalDataStatus.computeCurrent(hasActivity: hasActivity)
        lock.lock()
        Self.cached = (hasActivity, status, Date())
        lock.unlock()
        return status
    }

    /// Block observers are retained by this lazy initializer.
    private static let observers: Void = {
        let center = NotificationCenter.default
        center.addObserver(forName: LogScanObservation.didChange, object: nil, queue: .main) { _ in invalidate() }
        center.addObserver(forName: BookmarkManager.didChange, object: nil, queue: .main) { _ in invalidate() }
        center.addObserver(forName: .appHealthDidChange, object: nil, queue: .main) { _ in invalidate() }
        return ()
    }()
}

extension LocalDataStatus {
    static func current(hasActivity: Bool? = nil) -> Self {
        LocalDataStatusCache.current(hasActivity: hasActivity)
    }

    static func computeCurrent(hasActivity: Bool?) -> Self {
        let fm = FileManager.default
        let home: Access = !BookmarkManager.isSandboxed ? .notRequired
            : BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) && fm.isReadableFile(atPath: BookmarkManager.homeDirPath) ? .granted
            : BookmarkManager.hasHomeAccess ? .expired : .missing
        let readable = logPaths.contains { BookmarkManager.isAccessAvailable(for: $0) && fm.isReadableFile(atPath: $0) }
            || RepositoryScope.configuredRoots().contains { root in
                BookmarkManager.isAccessAvailable(for: root) && RepoScanCache.shared.cachedScan(for: root)?.repos.contains {
                    fm.isReadableFile(atPath: $0.path + "/.aider.chat.history.md") || fm.isReadableFile(atPath: $0.path + "/.aider.llm.history")
                } == true
            }
        let roots = RepositoryScope.configuredRoots()
        let failed = AppHealthMonitor.shared.failingIngestSources.contains { $0.lowercased().hasPrefix("log.") }
        return resolve(homeAccess: home, hasReadableLogs: readable,
                       scan: LogScanObservation.shared.status(hasReadFailure: failed), hasActivity: hasActivity,
                       rootsConfigured: !roots.isEmpty,
                       rootsAccessible: roots.allSatisfy { BookmarkManager.isAccessAvailable(for: $0) },
                       rootsExist: roots.allSatisfy { fm.isReadableFile(atPath: $0) },
                       priorReadUsable: LogScanObservation.shared.lastCompletedAt.map {
                           let age = Date().timeIntervalSince($0)
                           return age >= 0 && age <= 120
                       } ?? false)
    }
}

enum SetupCopy {
    static func text(_ zh: String, _ en: String) -> String { I18n.prototype(zh, en) }
    static func activity(_ state: LocalDataStatus.Activity) -> String {
        switch state {
        case .needsAccess: return text("授权主目录以读取活动", "Authorize home to read activity")
        case .accessExpired: return text("主目录授权已失效", "Home access needs renewal")
        case .scanning: return text("正在读取本地活动…", "Reading local activity…")
        case .noSources: return text("尚未发现支持的工具日志", "No supported tool logs found")
        case .noActivity: return text("读取正常，当前暂无活动", "Sources ready; no activity yet")
        case .ready: return text("本地活动读取正常", "Local activity available")
        case .stale: return text("本地活动暂未更新", "Local activity is out of date")
        case .failed: return text("本地活动读取失败", "Local activity could not be read")
        }
    }
    static func repositories(_ state: LocalDataStatus.Repositories) -> String {
        switch state {
        case .notConfigured: return text("未配置开发目录", "Development folders not configured")
        case .needsAccess: return text("开发目录需要重新授权", "Development folders need access")
        case .missing: return text("开发目录不存在或不可读取", "Development folders unavailable")
        case .ready: return text("开发目录已配置", "Development folders configured")
        }
    }
}
