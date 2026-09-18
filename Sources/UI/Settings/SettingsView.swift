import SwiftUI
import GRDB
import AppKit
import CloudKit
import AIPulseShared

// MARK: - Main Settings

struct SettingsView: View {
    @State private var selectedTab: String
    @State private var lang = I18n.getLang()
    @State private var integrationsExpanded = true   // default expand sub-tabs

    init(initialTab: String = "General") {
        _selectedTab = State(initialValue: initialTab)
    }
    var langBinding: Binding<String> {
        Binding(get: { lang }, set: { v in lang = v; I18n.setLang(v) })
    }

    func labelFor(_ key: String) -> String {
        switch key {
        case "General": return I18n.t("settings.general")
        case "Notifications": return I18n.t("general.group_notifications")
        case "Integrations": return I18n.t("settings.integrations")
        case "integrations": return I18n.t("settings.integrations")
        case "integrations.api": return I18n.t("settings.integrations_api")
        case "integrations.dev": return I18n.t("settings.integrations_devtools")
        case "Repos": return I18n.t("settings.repos")
        case "About": return I18n.t("settings.about")
        default: return key
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                Label(labelFor("General"), systemImage: "gear")
                    .tag("General")
                Label(labelFor("Notifications"), systemImage: "bell.badge")
                    .tag("Notifications")
                Label(labelFor("Repos"), systemImage: "folder").tag("Repos")
                Label(labelFor("integrations.dev"), systemImage: "hammer").tag("integrations.dev")
                Label(SetupCopy.text("账户与固定费用", "Accounts & fixed costs"), systemImage: "creditcard").tag("integrations.api")
                Label(labelFor("About"), systemImage: "info.circle")
                    .tag("About")
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170)
        } detail: {
            Group {
                switch selectedTab {
                case "General":         GeneralTab(lang: langBinding).id("general.\(lang)")
                case "Notifications":   NotificationsTab().id("notifications.\(lang)")
                case "integrations":    IntegrationsOverviewTab().id("integrations.\(lang)")
                case "integrations.api": AccountAndCostsTab().id("integrations.api.\(lang)")
                case "integrations.dev": DevToolsTab().id("integrations.dev.\(lang)")
                case "Repos":          ReposTab().id("repos.\(lang)")
                case "About":          AboutTab().id("about.\(lang)")
                default: EmptyView()
                }
            }
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 700, height: 480)
        .onReceive(NotificationCenter.default.publisher(for: .showIntegrationsTab)) { _ in
            selectedTab = "integrations.api"
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsSwitchTab)) { notification in
            if let tab = notification.userInfo?["tab"] as? String {
                selectedTab = tab
            }
        }
    }
}

// MARK: - Integrations

/// Overview page for the "Integrations" parent item — explains how AI Pulse
/// tracks AI coding tools across the two sub-categories.
struct IntegrationsOverviewTab: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18n.t("integrations.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("integrations.desc"))
                .font(.caption).foregroundColor(.secondary)

            infoRow(systemImage: "server.rack",
                    title: I18n.t("settings.integrations_api"),
                    body: I18n.t("integrations.group_api_key_desc"))
            infoRow(systemImage: "hammer",
                    title: I18n.t("settings.integrations_devtools"),
                    body: I18n.t("integrations.group_editors_desc"))
            infoRow(systemImage: "lock.shield",
                    title: I18n.t("settings.integrations_privacy_title"),
                    body: SetupCopy.text("日志在本机读取；正式版同步仪表盘摘要到你的 iCloud 私有数据库，不同步 API 密钥。", "Logs are read locally; release builds sync dashboard summaries to your private iCloud database, without API keys."))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func infoRow(systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).font(.title3).foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body).fontWeight(.medium)
                Text(body).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}

/// Integration category shown in the sidebar sub-tabs.
enum IntegrationCategory {
    case apiKeys       // AI providers (balance polling)
    case devTools      // log/subscription dev tools

    static func category(for integration: any Detectable) -> IntegrationCategory {
        let apiKeyOnlyIds = Set(["deepseek", "openai", "moonshot", "zhipu", "anthropic"])
        return apiKeyOnlyIds.contains(integration.id) ? .apiKeys : .devTools
    }
}

/// AI 服务商 — API-key providers with balance polling.
struct ApiProvidersTab: View {
    var body: some View {
        IntegrationGroupedTab(category: .apiKeys)
    }
}

/// 开发工具 — log-based (Claude/Codex/Qwen) + subscription (Cursor/Copilot/Windsurf).
/// Includes the home-directory grant (sandbox) since it gates log-based detection.
struct DevToolsTab: View {
    var body: some View {
        IntegrationGroupedTab(category: .devTools)
    }
}

/// Shared grouped-integrations list, filtered to one category.
struct IntegrationGroupedTab: View {
    let category: IntegrationCategory
    @State private var results: [(any Detectable, DetectionResult)] = []
    @State private var isDetecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(category == .apiKeys
                     ? I18n.t("settings.integrations_api")
                     : I18n.t("settings.integrations_devtools"))
                    .font(.title3).fontWeight(.semibold)
                Spacer()
                if isDetecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button(I18n.t("integrations.redetect")) { reDetect() }.font(.caption)
                }
            }
            // Category-specific description (substantive, not a repetition of
            // the sidebar label).
            Text(category == .apiKeys
                 ? SetupCopy.text("可选账户观测，不补全本地词元，也不影响基础活动统计。", "Optional account observations; they do not complete local tokens or affect activity tracking.")
                 : SetupCopy.text("自动读取支持的本地日志；套餐配置与活动读取无关。", "Supported local logs are read automatically, independently of subscription plans."))
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    if category == .devTools {
                        devToolsAccessBanner
                    }
                    ForEach(results.filter { IntegrationCategory.category(for: $0.0) == category },
                            id: \.0.id) { (i, r) in
                        IntegrationRow(integration: i, detected: r, showPlan: category != .devTools,
                                       onGrant: { runDetection() })
                    }
                }
                .padding(.trailing, 16)
            }
        }
        .onAppear {
            runDetection()
            ApiPoller.shared.pollAll()
        }
        // Re-run detection when the shared repo-scan cache warms up, so aider
        // (cache-backed since AiderIntegration.detect() reads RepoScanCache)
        // updates from "not detected" to "detected" after a cold/stale cache
        // without requiring a manual Redetect. Converges: once the cache is
        // fresh, detect() stops firing background scans, so no notification loop.
        .onReceive(NotificationCenter.default.publisher(for: RepoScanCache.didChange)) { _ in
            runDetection()
        }
    }

    /// Sandbox: home-directory grant state for log-based tool detection.
    @ViewBuilder
    private var devToolsAccessBanner: some View {
        if BookmarkManager.isSandboxed {
            HStack(spacing: 8) {
                Image(systemName: BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) ? "checkmark.shield" : "lock.open")
                    .foregroundColor(BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) ? .green : .secondary)
                if BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) {
                    Text("\(I18n.t("settings.granted_path")) \(BookmarkManager.homeDirPath)")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(I18n.t("onboarding.grant_home_hint"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !BookmarkManager.isAccessAvailable(for: BookmarkManager.homeDirPath) {
                    Button(I18n.t("bookmark.grant_to_detect")) { grantHomeAccess() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    func runDetection() {
        results = IntegrationRegistry.visible.map { ($0, $0.detect()) }
    }

    func reDetect() {
        isDetecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            results = IntegrationRegistry.visible.map { ($0, $0.detect()) }
            isDetecting = false
        }
    }

    /// Grant home-folder access (sandbox) then re-detect all integrations.
    private func grantHomeAccess() {
        guard BookmarkManager.requestHomeAccess(message: I18n.t("bookmark.home_message")) != nil
        else { return }
        LogWatcher.shared.start()
        DataRefreshCoordinator.shared.triggerIngest()
        reDetect()
    }
}

struct AccountAndCostsTab: View {
    @State private var revision = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(SetupCopy.text("账户与固定费用", "Accounts & fixed costs")).font(.title3).bold()
                Text(SetupCopy.text("这些都是可选项，不影响词元活动与仓库变化。账户观测、固定月费各自呈现，不合并成账单。", "These optional settings do not affect token activity or repository changes. Account observations and fixed monthly costs remain separate, not a combined bill."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(SetupCopy.text("账户观测", "Account observations")).font(.headline)
                Text(SetupCopy.text("仅支持服务商提供的账户接口。密钥保存在本机偏好设置中，不使用钥匙串、不随 iCloud 摘要同步。", "Uses account APIs provided by each service. Keys are stored in local preferences, not Keychain, and are excluded from iCloud summaries."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(IntegrationRegistry.visible.filter { IntegrationCategory.category(for: $0) == .apiKeys }, id: \.id) { integration in
                    IntegrationRow(integration: integration, detected: integration.detect())
                }
                Text(SetupCopy.text("声明固定月费", "Declared fixed monthly costs")).font(.headline)
                Text(SetupCopy.text("由你声明的套餐背景，不是实际付款、剩余额度或词元统计的依据。选择无固定订阅可以移除这项月费。", "Plans you declare are context, not payment receipts, remaining quota or the basis of token statistics. Choose no fixed subscription to remove a monthly cost."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(IntegrationRegistry.visible.filter { ["claude-code", "codex", "cursor", "copilot", "windsurf"].contains($0.id) }, id: \.id) { integration in
                    IntegrationRow(integration: integration, detected: integration.detect())
                }
            }.padding(.trailing, 12)
        }
        .onAppear { ApiPoller.shared.pollAll() }
    }
}

// MARK: - Repos

private let repoDirsKey = "repo_search_dirs"

struct ReposTab: View {
    @State private var dirEntries: [DirEntry] = []
    /// path → repo count; a missing key means the dir is still scanning.
    /// @State-driven so the row re-renders deterministically when a scan lands
    /// (we do not rely on onReceive re-reading the singleton).
    @State private var repoCounts: [String: Int] = [:]
    @State private var deleteTarget: String? = nil
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18n.t("repos.title")).font(.title3).fontWeight(.semibold)

            ScrollView {
                VStack(spacing: 4) {
                    if dirEntries.isEmpty {
                        Text(I18n.t("repos.grant_empty"))
                            .font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    ForEach($dirEntries) { $entry in
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundColor(.accentColor)
                            Text(entry.path).font(.body).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            if let count = repoCounts[entry.path] {
                                Text("\(count)")
                                    .font(.caption2).foregroundColor(.secondary)
                                    .padding(.horizontal, 5)
                                    .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                            } else {
                                // Static placeholder — an indeterminate
                                // ProgressView with scaleEffect can trigger the
                                // AppKit "layoutSubtreeIfNeeded during layout"
                                // recursion warning.
                                Text(verbatim: "…").font(.caption2).foregroundColor(.secondary)
                            }
                            Button { deleteTarget = entry.path; showDelete = true } label: {
                                Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                    }
                }
            }

            HStack {
                Button(action: pickDir) {
                    Label(I18n.t("repos.add"), systemImage: "plus.circle").font(.caption)
                }
                Spacer()
            }

            let totalRepos = repoCounts.values.reduce(0, +)
            Text(String(format: I18n.t("repos.summary"), dirEntries.count, totalRepos))
                .font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { loadAndScan() }
        .onReceive(NotificationCenter.default.publisher(for: RepoScanCache.didChange)) { _ in
            refreshCounts()   // live-update as the walk finds repos
        }
        .alert(I18n.t("repos.delete_title"), isPresented: $showDelete) {
            Button(I18n.t("repos.cancel"), role: .cancel) {}
            Button(I18n.t("repos.remove"), role: .destructive) {
                if let d = deleteTarget {
                    dirEntries.removeAll { $0.path == d }
                    RepoScanCache.shared.invalidate(dir: d)
                    refreshCounts()
                    save()
                }
            }
        } message: { Text(String(format: I18n.t("repos.delete_msg"), deleteTarget ?? "") + "\n" + SetupCopy.text("只停止后续监控，已有历史记录保留。", "Only future monitoring stops; existing history is retained.")) }
    }

    // MARK: - Scanning

    private func loadAndScan() {
        let dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        dirEntries = dirs.map { DirEntry(path: $0) }
        // Background-scan any dir without a fresh cache entry. Refreshing the
        // visible counts directly after each scan completes (not only via the
        // didChange notification) guarantees the row stops spinning.
        for entry in dirEntries where RepoScanCache.shared.cachedScan(for: entry.path) == nil {
            Task {
                await RepoScanCache.shared.scan(dir: entry.path)
                refreshCounts()
            }
        }
        refreshCounts()
    }

    /// Copy fresh cache counts into @State so the rows re-render.
    private func refreshCounts() {
        var counts: [String: Int] = [:]
        for entry in dirEntries {
            if let scan = RepoScanCache.shared.cachedScan(for: entry.path) {
                counts[entry.path] = scan.repos.count
            }
        }
        repoCounts = counts
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = I18n.t("bookmark.grant")
        panel.message = I18n.t("bookmark.repos_message")
        panel.directoryURL = FileManager.default.realHomeDirectory
        if panel.runModal() == .OK, let url = panel.url {
            BookmarkManager.createAndSave(for: url)
            // Store the absolute path. `NSOpenPanel` returns an absolute path;
            // persisting it as-is keeps scans working under sandbox, where a
            // tilde-relative path could resolve against the wrong home directory.
            let p = url.path
            guard !dirEntries.contains(where: { $0.path == p }) else { return }
            dirEntries.append(DirEntry(path: p))
            save()
            Task { await RepoScanCache.shared.scan(dir: p) }
            LogWatcher.shared.start()
            DataRefreshCoordinator.shared.triggerIngest()
        }
    }

    private func save() {
        UserDefaults.standard.set(dirEntries.map(\.path), forKey: repoDirsKey)
    }
}

// MARK: - About

struct AboutTab: View {
    @State private var showAcknowledgments = false
    @State private var companionMissing = false

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIconLoader.uiImage(size: 64))
            Text(I18n.t("about.title")).font(.title).fontWeight(.bold)
            Text("AI Pulse v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0")").font(.caption).foregroundColor(.secondary)
            Text("CloudKit \(CKSchema.payloadVersion)")
                .font(.caption).foregroundColor(.secondary)
            Text(I18n.t("about.desc")).multilineTextAlignment(.center)

            if companionMissing {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title3).foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(I18n.t("about.companion_missing")).font(.body).fontWeight(.medium)
                        Text(I18n.t("about.companion_missing_desc"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(I18n.t("about.companion_appstore")) {
                        openCompanionAppStore()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .frame(maxWidth: 460)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
                )
            }

            Text(SetupCopy.text("本地日志保留在本机；正式版通过你的 iCloud 私有数据库同步仪表盘摘要。", "Local logs stay on this Mac; release builds sync dashboard summaries through your private iCloud database.")).font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 16) {
                Button(I18n.t("about.privacy_link")) {
                    NSWorkspace.shared.open(URL(string: "https://xingyu.wang/apps/ai-pulse/privacy")!)
                }
                Button(I18n.t("about.website")) {
                    NSWorkspace.shared.open(URL(string: "https://xingyu.wang/apps/ai-pulse/about")!)
                }
                Button(I18n.t("about.source_code")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/wxy/ai-pulse-macos")!)
                }
                Button(I18n.t("about.acknowledgments")) {
                    showAcknowledgments = true
                }
            }
            .buttonStyle(.link)

            Text(I18n.t("about.feedback"))
                .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)

            Divider().frame(width: 200)

            VStack(spacing: 4) {
                Text(I18n.t("about.license_title")).font(.caption).fontWeight(.semibold)
                Text(I18n.t("about.license_desc"))
                    .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
                Text(I18n.t("about.audio_credit"))
                    .font(.caption2).foregroundColor(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            checkCompanionApps()
        }
        .sheet(isPresented: $showAcknowledgments) {
            AcknowledgmentsView(isPresented: $showAcknowledgments)
        }
    }

    private func checkCompanionApps() {
        Task {
            do {
                let database = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
                let subscriptions = try await database.allSubscriptions()
                let hasCompanion = subscriptions.contains { subscription in
                    subscription.subscriptionID == CKSchema.Subscription.dashboardChanges
                        || subscription.subscriptionID == CKSchema.Subscription.spendAlertChanges
                }
                companionMissing = !hasCompanion
            } catch {
                // If CloudKit is unavailable we don't know the answer yet, so
                // don't show a potentially wrong download prompt.
                companionMissing = false
            }
        }
    }

    private func openCompanionAppStore() {
        guard let url = URL(string: "https://apps.apple.com/app/id6786290416") else { return }
        NSWorkspace.shared.open(url)
    }
}
