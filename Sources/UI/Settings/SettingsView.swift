import SwiftUI
import GRDB
import AppKit
import ServiceManagement

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
                // Parent "Integrations" is clickable (shows an overview in the
                // detail pane) and expands into its two sub-tabs.
                DisclosureGroup(isExpanded: $integrationsExpanded) {
                    Label(labelFor("integrations.api"), systemImage: "server.rack")
                        .tag("integrations.api")
                    Label(labelFor("integrations.dev"), systemImage: "hammer")
                        .tag("integrations.dev")
                } label: {
                    Label(labelFor("Integrations"), systemImage: "square.grid.2x2")
                        .tag("integrations")
                }
                Label(labelFor("Repos"), systemImage: "folder")
                    .tag("Repos")
                Label(labelFor("About"), systemImage: "info.circle")
                    .tag("About")
            }
            .listStyle(.sidebar)
            .frame(minWidth: 170)
        } detail: {
            Group {
                switch selectedTab {
                case "General":         GeneralTab(lang: langBinding).id("general.\(lang)")
                case "integrations":    IntegrationsOverviewTab().id("integrations.\(lang)")
                case "integrations.api": ApiProvidersTab().id("integrations.api.\(lang)")
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
                    body: I18n.t("settings.integrations_privacy_body"))

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
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(I18n.t("integrations.redetect")) { reDetect() }.font(.caption)
                }
            }
            // Category-specific description (substantive, not a repetition of
            // the sidebar label).
            Text(category == .apiKeys
                 ? I18n.t("integrations.group_api_key_desc")
                 : I18n.t("integrations.group_editors_desc"))
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 12) {
                    if category == .devTools {
                        devToolsAccessBanner
                    }
                    ForEach(results.filter { IntegrationCategory.category(for: $0.0) == category },
                            id: \.0.id) { (i, r) in
                        IntegrationRow(integration: i, detected: r,
                                       onGrant: { runDetection() })
                    }
                }
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
                Image(systemName: BookmarkManager.hasHomeAccess ? "checkmark.shield" : "lock.open")
                    .foregroundColor(BookmarkManager.hasHomeAccess ? .green : .secondary)
                if BookmarkManager.hasHomeAccess {
                    Text("\(I18n.t("settings.granted_path")) \(BookmarkManager.homeDirPath)")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text(I18n.t("onboarding.grant_home_hint"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if !BookmarkManager.hasHomeAccess {
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
        reDetect()
    }
}

// MARK: - General

struct GeneralTab: View {
    @Binding var lang: String
    @State private var coinSoundEnabled = UserDefaults.standard.bool(forKey: "coin_sound_enabled")
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var demoActive = DemoData.isActive

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("general.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("general.desc")).font(.caption).foregroundColor(.secondary)

            HStack {
                Text(I18n.t("general.language_label"))
                    .frame(width: 140, alignment: .leading)
                Picker("", selection: $lang) {
                    ForEach(I18n.supportedLanguages, id: \.code) { lang in
                        if lang.code == "auto" {
                            Text(I18n.t("settings.language_auto")).tag("auto")
                        } else {
                            Text(lang.label).tag(lang.code)
                        }
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 200)
            }

            Divider().padding(.vertical, 8)

            // Coin sound toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n.t("general.coin_sound")).font(.body)
                    Text(I18n.t("general.coin_sound_desc"))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $coinSoundEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: coinSoundEnabled) { _, v in
                        UserDefaults.standard.set(v, forKey: "coin_sound_enabled")
                    }
            }

            Divider().padding(.vertical, 8)

            // Launch at login
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(I18n.t("general.launch_at_login")).font(.body)
                    Text(I18n.t("general.launch_at_login_desc"))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, v in
                        do {
                            if v { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Divider().padding(.vertical, 8)

            // Demo mode toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(demoActive ? I18n.t("demo.exit") : I18n.t("demo.enter"))
                        .font(.body)
                    Text(I18n.t("demo.onboarding_msg"))
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
                Button(demoActive ? I18n.t("demo.exit") : I18n.t("demo.enter")) {
                    if DemoData.isActive {
                        DemoData.isManual = false
                        DemoData.isSuppressed = true
                    } else {
                        DemoData.isSuppressed = false
                        DemoData.isManual = true
                    }
                    NotificationCenter.default.post(name: .demoModeDidChange, object: nil)
                    NotificationCenter.default.post(name: .dataDidChange, object: nil)
                }
            }

            Divider().padding(.vertical, 8)

            Text(I18n.t("general.rerun_welcome_desc"))
                .font(.caption).foregroundColor(.secondary)
            Button(I18n.t("general.rerun_welcome")) {
                UserDefaults.standard.removeObject(forKey: "onboarding_completed")
                // Re-open onboarding
                if let w = OnboardingWindowManager.shared.window { w.close() }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = I18n.t("onboarding.window_title")
                w.contentView = NSHostingView(rootView: OnboardingView())
                w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
                OnboardingWindowManager.shared.window = w
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .demoModeDidChange)) { _ in
            demoActive = DemoData.isActive
        }
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
                                ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
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
        } message: { Text(String(format: I18n.t("repos.delete_msg"), deleteTarget ?? "")) }
    }

    // MARK: - Scanning

    private func loadAndScan() {
        let dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        if dirs.isEmpty {
            // Under sandbox, unauthorized guessed defaults can't be read; show an
            // empty state + Add button instead of persisting/scanning unreadable dirs.
            if BookmarkManager.isSandboxed {
                dirEntries = []
            } else {
                let defaults = ["~/dev", "~/projects", "~/code"]
                UserDefaults.standard.set(defaults, forKey: repoDirsKey)
                dirEntries = defaults.map { DirEntry(path: $0) }
            }
        } else {
            dirEntries = dirs.map { DirEntry(path: $0) }
        }
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

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIconLoader.uiImage(size: 64))
            Text(I18n.t("about.title")).font(.title).fontWeight(.bold)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"))").font(.caption).foregroundColor(.secondary)
            Text(I18n.t("about.desc")).multilineTextAlignment(.center)
            Text(I18n.t("about.privacy")).font(.caption2).foregroundColor(.secondary)
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
        .sheet(isPresented: $showAcknowledgments) {
            AcknowledgmentsView()
        }
    }
}
