import SwiftUI
import AIPulseShared

struct DirEntry: Identifiable {
    let id = UUID()
    let path: String           // e.g. "~/dev"
    var isChecked: Bool = false
    var repoCount: Int = 0
    var repos: [String] = []   // lastPathComponent only
    var isScanning: Bool = false
    var isExpanded: Bool = false
}

struct OnboardingView: View {
    @State private var step = 0
    @State private var status = LocalDataStatus.current()
    @State private var roots = RepositoryScope.configuredRoots()
    @State private var detectedTools: [String] = []
    @State private var counts: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule().fill(index <= step ? Color.marsGreen : Color.secondary.opacity(0.15))
                        .frame(width: 22, height: 4)
                }
            }.padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if step == 0 { welcome }
                    else if step == 1 { access }
                    else { completion }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if step > 0 { Button(I18n.t("onboarding.back")) { step -= 1 } }
                Spacer()
                Button(step == 2 ? SetupCopy.text("打开仪表盘", "Open dashboard") : step == 1 && !status.canReportCurrentActivity ? SetupCopy.text("稍后配置并继续", "Configure later") : I18n.t("onboarding.next")) {
                    if step < 2 { step += 1 } else { finish() }
                }.buttonStyle(.borderedProminent).tint(.marsGreen)
            }
        }
        .padding(24).frame(width: 520, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkManager.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: RepoScanCache.didChange)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LogScanObservation.didChange)) { _ in refresh() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: AppIconLoader.uiImage(size: 64))
            Text(SetupCopy.text("看见你的 AI 开发活动", "See your AI development activity")).font(.title2).bold()
            Text(SetupCopy.text("从本地工具日志读取词元活动，从你选择的仓库统计代码变化。先授权主目录，开发目录可以稍后添加。", "Read token activity from local tool logs and code changes from repositories you choose. Start with home access; development folders can wait."))
                .font(.body)
            SetupCard {
                Label(SetupCopy.text("无需 API Key 或套餐即可开始", "No API key or plan required to start"), systemImage: "checkmark.circle")
                Text(SetupCopy.text("账户观测和固定费用都是可选配置，可以以后在设置中添加。", "Account observations and fixed costs are optional and can be configured later."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(SetupCopy.text("日志在本机读取和存储；正式版会将仪表盘摘要同步到你的 iCloud 私有数据库。API 密钥保存在本机，不随摘要同步。", "Logs are read and stored locally. Release builds sync dashboard summaries to your private iCloud database. API keys stay local and are not included in summaries."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SetupCopy.text("连接本地活动", "Connect local activity")).font(.title2).bold()
            SetupCard {
                HStack {
                    Label(SetupCopy.text("主目录访问", "Home folder access"), systemImage: "house")
                    Spacer()
                    if status.homeAccess == .granted || status.homeAccess == .notRequired {
                        Image(systemName: "checkmark.circle").foregroundStyle(Color.marsGreen)
                    } else {
                        Button(SetupCopy.text("授权主目录", "Authorize home")) {
                            guard BookmarkManager.requestHomeAccess(message: I18n.t("bookmark.home_message")) != nil else { return }
                            startReading(); refresh()
                        }.buttonStyle(.bordered)
                    }
                }
                Text(SetupCopy.text("用于读取主目录下支持的开发工具日志；不会因此扫描所有仓库。", "Reads supported tool logs under home; it does not scan every repository."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(SetupCopy.activity(status.activity)).font(.caption)
            }
            SetupCard {
                HStack {
                    Label(SetupCopy.text("开发目录 · 可选", "Development folders · optional"), systemImage: "folder")
                    Spacer()
                    Button(SetupCopy.text("添加目录", "Add folder")) { addFolder() }.buttonStyle(.bordered)
                }
                Text(SetupCopy.text("选择包含项目的上级目录，可以添加多个；没有配置时仍可显示工具词元活动。", "Choose parent folders containing projects. You can add several; token activity works without them."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(roots, id: \.self) { root in
                    HStack {
                        Text(root).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(counts[root].map { SetupCopy.text("\($0) 个仓库", "\($0) repositories") } ?? SetupCopy.text("扫描中", "Scanning"))
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var completion: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(SetupCopy.text("准备好打开仪表盘", "Ready to open the dashboard")).font(.title2).bold()
            SetupCard {
                Text(SetupCopy.activity(status.activity))
                Text(SetupCopy.repositories(status.repositories))
                if !detectedTools.isEmpty { Text(detectedTools.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }
            Text(SetupCopy.text("额头显示当前活动强度，左眼显示词元，右眼显示仓库代码变化。下方时间切换只影响历史统计。", "The forehead shows current intensity, the left eye tokens and the right eye repository changes. The range switch affects historical statistics only."))
            Text(SetupCopy.text("未授权或未配置的部分会显示等待配置；你随时可以在设置中补充，也不必等完整历史扫描结束。", "Unconfigured sources show a setup state. You can finish configuration in Settings without waiting for the full historical scan."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        status = LocalDataStatus.current()
        roots = RepositoryScope.configuredRoots()
        detectedTools = IntegrationRegistry.visible.filter { IntegrationCategory.category(for: $0) == .devTools && $0.detect().found }.map { $0.displayName }
        for root in roots { counts[root] = RepoScanCache.shared.cachedScan(for: root)?.repos.count }
    }
    private func startReading() {
        LogWatcher.shared.start()
        DataRefreshCoordinator.shared.triggerIngest()
    }
    private func addFolder() {
        guard let url = BookmarkManager.requestAccess(message: I18n.t("bookmark.repos_message"), defaultDirectory: BookmarkManager.homeDirPath) else { return }
        var selected = RepositoryScope.configuredRoots()
        if !selected.contains(url.path) { selected.append(url.path) }
        UserDefaults.standard.set(selected, forKey: "repo_search_dirs")
        refresh()
        Task { await RepoScanCache.shared.scan(dir: url.path); refresh() }
        startReading()
    }
    private func finish() {
        UserDefaults.standard.set(true, forKey: "onboarding_completed")
        startReading()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        OnboardingWindowManager.shared.window?.close()
        DashboardWindowManager.shared.openOrBringToFront()
    }
}

// MARK: - Window Manager

extension Notification.Name {
    static let dashboardRefresh = Notification.Name("dashboardRefresh")
    static let showIntegrationsTab = Notification.Name("showIntegrationsTab")
    static let demoModeDidChange = Notification.Name("demoModeDidChange")
}

final class OnboardingWindowManager: @unchecked Sendable {
    static let shared = OnboardingWindowManager()
    var window: NSWindow?
}
