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
                        hasActivity: Bool, rootsConfigured: Bool, rootsAccessible: Bool, rootsExist: Bool) -> Self {
        let activity: Activity
        if !hasReadableLogs && homeAccess == .missing { activity = .needsAccess }
        else if !hasReadableLogs && homeAccess == .expired { activity = .accessExpired }
        else if scan == .failed { activity = .failed }
        else if !hasReadableLogs { activity = .noSources }
        else if scan == .scanning || scan == .inactive { activity = .scanning }
        else if scan == .stale { activity = .stale }
        else { activity = hasActivity ? .ready : .noActivity }
        let repositories: Repositories = !rootsConfigured ? .notConfigured
            : !rootsAccessible ? .needsAccess : !rootsExist ? .missing : .ready
        return Self(homeAccess: homeAccess, activity: activity, repositories: repositories)
    }

    var canReportCurrentActivity: Bool { activity == .ready || activity == .noActivity }

    static var logPaths: [String] {
        [".claude/projects", ".codex/sessions", ".dsh/sessions", ".qwen/projects", ".local/share/opencode/storage/message"]
            .map { FileManager.default.realHomeDirectory.appendingPathComponent($0).path }
    }

    static func current(hasActivity: Bool = false) -> Self {
        let fm = FileManager.default
        let home: Access = !BookmarkManager.isSandboxed ? .notRequired
            : BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) ? .granted
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
                       rootsExist: roots.allSatisfy { fm.isReadableFile(atPath: $0) })
    }
}

enum SetupCopy {
    static func text(_ zh: String, _ en: String) -> String { I18n.resolvedLang() == "zh-Hans" ? zh : en }
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
