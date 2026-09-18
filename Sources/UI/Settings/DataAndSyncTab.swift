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
    @State private var copied = false
    private var sync: CloudSyncService { .shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SetupCopy.text("数据与同步", "Data & sync")).font(.title3).bold()
                SetupCard {
                    Text(SetupCopy.text("本地数据", "Local data")).font(.headline)
                    Text(SetupCopy.activity(status.activity))
                    Text(SetupCopy.repositories(status.repositories)).foregroundStyle(.secondary)
                    Text(SetupCopy.text("最近扫描完成：", "Last completed scan: ") + (LogScanObservation.shared.lastCompletedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = AppDatabase.shared.databaseURL {
                        Text(url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Button(SetupCopy.text("在访达中显示数据库", "Show database in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    HStack {
                        Button(refreshing ? SetupCopy.text("正在重新读取…", "Reading again…") : SetupCopy.text("重新读取活动与仓库", "Read activity & repositories again")) { reread() }
                            .disabled(refreshing)
                        Button(SetupCopy.text("管理目录", "Manage folders")) {
                            NotificationCenter.default.post(name: .settingsSwitchTab, object: nil, userInfo: ["tab": "Repos"])
                        }
                    }
                    if status.homeAccess == .missing || status.homeAccess == .expired {
                        Button(SetupCopy.text("重新授权主目录", "Authorize home folder")) {
                            guard BookmarkManager.requestHomeAccess(message: I18n.t("bookmark.home_message")) != nil else { return }
                            reread()
                        }
                    }
                    Text(SetupCopy.text("重新读取不会删除历史记录；主目录权限和仓库统计范围各自独立。", "Reading again preserves history. Home access and repository scope are independent."))
                        .font(.caption).foregroundStyle(.secondary)
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
                    Text(SetupCopy.text("诊断与版本", "Diagnostics & versions")).font(.headline)
                    Text("AI Pulse " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") + " · " + SetupCopy.text("数据格式 ", "Data format ") + CKSchema.payloadVersion)
                    HStack {
                        Button(SetupCopy.text("查看本地日志", "Show local log")) { NSWorkspace.shared.activateFileViewerSelecting([Logger.logFileURL]) }
                        Button(copied ? SetupCopy.text("已复制", "Copied") : SetupCopy.text("复制状态摘要", "Copy status summary")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(diagnostics, forType: .string)
                            copied = true
                        }
                    }
                    Text(SetupCopy.text("状态摘要不含密钥、仓库路径或会话正文。", "The status summary excludes keys, repository paths and session text."))
                        .font(.caption).foregroundStyle(.secondary)
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

    private var diagnostics: String {
        ["AI Pulse " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"),
         "Data format: " + CKSchema.payloadVersion,
         SetupCopy.activity(status.activity), SetupCopy.repositories(status.repositories),
         sync.accountText, sync.resultText].joined(separator: "\n")
    }
    private func refresh() {
        status = LocalDataStatus.current()
        accountText = sync.accountText
        resultText = sync.resultText
        lastSuccess = sync.lastSuccess
        syncResult = sync.result
        copied = false
    }
    private func reread() {
        guard !refreshing else { return }
        refreshing = true
        LogWatcher.shared.start()
        DataRefreshCoordinator.shared.triggerIngest()
        Task {
            let roots = RepositoryScope.configuredRoots()
            for root in roots { RepoScanCache.shared.invalidate(dir: root); await RepoScanCache.shared.scan(dir: root) }
            _ = await Task.detached(priority: .utility) { RepoDiscovery.scan() }.value
            await DashboardCache.invalidateAll()
            DataRefreshCoordinator.shared.notifyDataChange()
            refreshing = false
            refresh()
        }
    }
}
