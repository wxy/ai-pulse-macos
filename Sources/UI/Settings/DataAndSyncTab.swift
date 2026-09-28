import SwiftUI
import Combine
import AppKit
import AIPulseShared

struct DataAndSyncTab: View {
    @State private var status = LocalDataStatus.current()
    @State private var accountText = ""
    @State private var resultText = ""
    @State private var lastSuccess: Date?
    @State private var syncResult = CloudSyncService.Result.idle
    @State private var refreshing = false
    @State private var sourceFacts: [SourceHealthFact] = []
    private var sync: CloudSyncService { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SetupCopy.text("数据与同步", "Data & sync")).font(.title3).bold()
                SetupCard {
                    HStack {
                        Text(SetupCopy.text("工具日志读取", "Tool log reading")).font(.headline)
                        Spacer()
                        Button(SetupCopy.text("查看工具与授权", "Tools & access")) { openSettingsTab("integrations.dev") }
                    }
                    Text(logStatusText)
                    Text(SetupCopy.text("从支持的开发工具日志中读取词元活动，不代表仓库代码已经扫描，也不保证所有工具都提供日志。", "Reads token activity from supported developer tool logs. This does not mean repository code has been scanned or that every tool provides logs."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(SetupCopy.text("最近日志扫描完成：", "Last completed log scan: ") + (LogScanObservation.shared.lastCompletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(SetupCopy.text("重新扫描工具日志", "Rescan tool logs")) {
                        LogWatcher.shared.start()
                        DataRefreshCoordinator.shared.triggerIngest()
                    }
                }
                sourceHealthCard
                SetupCard {
                    HStack {
                        Text(SetupCopy.text("仓库扫描", "Repository scanning")).font(.headline)
                        Spacer()
                        Button(SetupCopy.text("授权与管理开发目录", "Authorize & manage development folders")) { openSettingsTab("Repos") }
                    }
                    Text(SetupCopy.repositories(status.repositories))
                    Text(SetupCopy.text("只扫描你指定的开发目录，用于发现 Git 仓库和统计代码变更；与主目录中的工具日志授权独立。", "Scans only your selected development folders to find Git repositories and track code changes, independently of home-folder log access."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(refreshing ? SetupCopy.text("正在扫描仓库…", "Scanning repositories…") : SetupCopy.text("重新扫描仓库", "Rescan repositories")) { rescanRepositories() }
                        .disabled(refreshing || RepositoryScope.configuredRoots().isEmpty)
                }
                SetupCard {
                    Text(SetupCopy.text("本机数据库", "Local database")).font(.headline)
                    Text(SetupCopy.text("保存已经采集的历史记录，不是日志来源或仓库扫描目录。", "Stores collected history; this is not a tool log source or a repository scanning folder."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = AppDatabase.shared.databaseURL {
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(SetupCopy.text("在访达中显示数据库", "Show database in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                exportCard
                SetupCard {
                    Text("iCloud").font(.headline)
                    Text(accountText)
                    Text(resultText)
                    Text(SetupCopy.text("最近成功同步：", "Last successful sync: ") + (lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(SetupCopy.text("正式版同步今日、本周、30 天摘要、当前强度及提醒；摘要含仓库名称和路径，不包含原始会话正文或 API 密钥。iCloud 同步不替代本地历史备份。", "Release builds sync today/week/30-day summaries, current intensity and alerts. Summaries include repository names and paths, but no raw session text or API keys. iCloud sync is not a backup of local history."))
                        .font(.caption).foregroundStyle(.secondary)
                    #if !DEBUG
                    Button(SetupCopy.text("检查并重试同步", "Check & retry sync")) {
                        Task { await sync.refreshAccount(); await sync.syncFromCache() }
                    }.disabled(syncResult == .syncing)
                    #endif
                }
                SetupCard {
                    Text(SetupCopy.text("支持与版本", "Support & versions")).font(.headline)
                    Text("AI Pulse " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") + " · " + SetupCopy.text("数据格式 ", "Data format ") + CKSchema.payloadVersion)
                    Button(SetupCopy.text("查看本地日志", "Show local log")) { NSWorkspace.shared.activateFileViewerSelecting([Logger.logFileURL]) }
                }
            }.font(.system(size: 13)).padding(.trailing, 12)
        }
        .task { await sync.refreshAccount(); refresh() }
        .onReceive(NotificationCenter.default.publisher(for: CloudSyncService.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkManager.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LogScanObservation.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .appHealthDidChange)) { _ in refresh() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // The settings window only orderOuts on close, so the timer keeps
            // firing while hidden — skip the main-thread disk probe then.
            guard SettingsWindowManager.shared.window?.isVisible == true else { return }
            refresh()
        }
    }

    private var logStatusText: String {
        switch status.activity {
        case .ready: return SetupCopy.text("工具日志可读取，最近扫描已完成", "Tool logs are readable; the latest scan completed")
        case .noActivity: return SetupCopy.text("工具日志扫描已完成，当前暂无词元活动", "Tool log scan completed; no token activity yet")
        default: return SetupCopy.activity(status.activity)
        }
    }

    // MARK: - Source health

    /// Per-source collection facts: last observation, window event count and
    /// missing-component count. "无观察" is an honest blind spot, not zero and
    /// not a fault; ingest errors come from the health monitor's own keys.
    private var sourceHealthCard: some View {
        SetupCard {
            HStack(alignment: .firstTextBaseline) {
                Text(SetupCopy.text("采集源健康", "Source health")).font(.headline)
                Spacer()
                Text(SetupCopy.text("近 7 天", "Last 7 days"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(SetupCopy.text("“最近入库”是来自该源的最近一次已观察事件；无观察不代表零用量，也不代表采集故障。", "“Last observed” is the most recent event seen from that source. No observation is neither zero usage nor a fault."))
                .font(.caption).foregroundStyle(.secondary)
            let failing = AppHealthMonitor.shared.failingIngestSources
            let rows = SourceHealth.orderedRows(facts: sourceFacts)
            ForEach(rows, id: \.source) { source, fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(IntegrationRegistry.toolDisplayName(for: source))
                        .font(.system(size: 12))
                    if failing.contains(source) {
                        Text(SetupCopy.text("采集异常", "Errors"))
                            .font(.caption2).bold()
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    if fact?.incomplete7d ?? 0 > 0 {
                        Text(SetupCopy.text("部分分项缺失", "partial components"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(fact.map { countText($0.events7d) + SetupCopy.text(" 事件", " events") } ?? SetupCopy.text("无观察", "no observation"))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(lastObservedText(fact?.lastEventMs))
                        .font(.system(size: 12)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 120, alignment: .trailing)
                }
            }
            let watchedRepos = GitMonitor.shared.watchedRepoPaths.count
            HStack(alignment: .firstTextBaseline) {
                Text(SetupCopy.text("Git 仓库监控", "Git repository watch")).font(.system(size: 12))
                if failing.contains(where: { $0.hasPrefix("Git.") }) {
                    Text(SetupCopy.text("采集异常", "Errors"))
                        .font(.caption2).bold().foregroundStyle(.orange)
                }
                Spacer()
                Text(watchedRepos == 1
                     ? SetupCopy.text("1 个仓库", "1 repository")
                     : String(format: SetupCopy.text("%lld 个仓库", "%lld repositories"), watchedRepos))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .trailing)
            }
        }
    }

    private func lastObservedText(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "—" }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func countText(_ value: Int64) -> String {
        value >= Int64(Int32.max) ? "—" : "\(value)"
    }

    // MARK: - Data export

    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var exporting = false

    /// Writes the four raw-unit tables into a timestamped folder inside the
    /// app container. The sandbox grants read-only access to user-selected
    /// locations, so instead of widening entitlements the export lands here
    /// and Finder reveals it — the user moves it wherever they like.
    private var exportCard: some View {
        SetupCard {
            Text(SetupCopy.text("导出数据", "Export data")).font(.headline)
            Text(SetupCopy.text("导出词元事件、余额快照、代码变更与提交四张表，按入库原样保存原单位数值：不求和、不换算币种、保留缺失为空，且不包含任何估价列。", "Exports token events, balance snapshots, code changes and commits exactly as stored: no sums, no currency conversion, missing values stay missing, and no price columns are included."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(exporting ? SetupCopy.text("正在导出…", "Exporting…") : SetupCopy.text("导出 CSV（4 个文件）", "Export CSV (4 files)")) { runExport(kind: .csv) }
                    .disabled(exporting)
                Button(SetupCopy.text("导出 JSON（单文件）", "Export JSON (single file)")) { runExport(kind: .json) }
                    .disabled(exporting)
            }
            if let exportURL {
                Text(exportURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(SetupCopy.text("在访达中显示导出文件", "Show export in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                }
            }
            if let exportError {
                Text(exportError).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private enum ExportKind { case csv, json }

    private func runExport(kind: ExportKind) {
        exporting = true
        exportError = nil
        Task.detached(priority: .utility) {
            do {
                let stamp = Self.exportStamp(Date())
                let directory = try Self.exportDirectory(stamp: stamp)
                let sections: [DataExport.Section] = try await AppDatabase.shared.read { db in
                    [
                        try DataExport.usageEvents(in: db),
                        try DataExport.balanceSnapshots(in: db),
                        try DataExport.codeChanges(in: db),
                        try DataExport.gitCommits(in: db),
                    ]
                }
                var files: [URL] = []
                switch kind {
                case .csv:
                    for section in sections {
                        let file = directory.appendingPathComponent("\(section.name).csv")
                        try DataExport.csv(section).write(to: file, atomically: true, encoding: .utf8)
                        files.append(file)
                    }
                case .json:
                    let file = directory.appendingPathComponent("aipulse-export-\(stamp).json")
                    try DataExport.jsonPayload(sections: sections, exportedAt: Date())
                        .write(to: file, options: .atomic)
                    files.append(file)
                }
                await MainActor.run {
                    exporting = false
                    exportURL = files.first.map { $0.deletingLastPathComponent() }
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    exportError = error.localizedDescription
                }
            }
        }
    }

    private nonisolated static func exportStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private nonisolated static func exportDirectory(stamp: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let directory = base
            .appendingPathComponent("AIPulse", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("export-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func loadSourceHealth() {
        let windowStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())
            .map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
        Task.detached(priority: .utility) {
            let facts = (try? await AppDatabase.shared.read { db in
                try SourceHealth.facts(in: db, windowStartMs: windowStart)
            }) ?? []
            await MainActor.run { sourceFacts = facts }
        }
    }
    private func openSettingsTab(_ tab: String) {
        NotificationCenter.default.post(name: .settingsSwitchTab, object: nil, userInfo: ["tab": tab])
    }
    private func refresh() {
        status = LocalDataStatus.current()
        accountText = sync.accountText
        resultText = sync.resultText
        lastSuccess = sync.lastSuccess
        syncResult = sync.result
        loadSourceHealth()
    }
    private func rescanRepositories() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            let roots = RepositoryScope.configuredRoots()
            for root in roots { RepoScanCache.shared.invalidate(dir: root); await RepoScanCache.shared.scan(dir: root) }
            _ = await Task.detached(priority: .utility) { RepoDiscovery.scan() }.value
            await DashboardCache.invalidateAll()
            LogWatcher.shared.start()
            DataRefreshCoordinator.shared.triggerIngest()
            DataRefreshCoordinator.shared.notifyDataChange()
            refreshing = false
            refresh()
        }
    }
}
