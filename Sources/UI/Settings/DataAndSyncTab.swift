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
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in refresh() }
    }

    private var logStatusText: String {
        switch status.activity {
        case .ready: return SetupCopy.text("工具日志可读取，最近扫描已完成", "Tool logs are readable; the latest scan completed")
        case .noActivity: return SetupCopy.text("工具日志扫描已完成，当前暂无词元活动", "Tool log scan completed; no token activity yet")
        default: return SetupCopy.activity(status.activity)
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
