import SwiftUI
import GRDB
import AppKit

// MARK: - Main Settings

struct SettingsView: View {
    @State private var selectedTab: String
    @State private var lang = I18n.getLang()

    init(initialTab: String = "General") {
        _selectedTab = State(initialValue: initialTab)
    }
    let tabs: [(String, String)] = [
        ("General", "gear"), ("Integrations", "square.grid.2x2"), ("Repos", "folder"),
        ("About", "info.circle"),
    ]

    var langBinding: Binding<String> {
        Binding(get: { lang }, set: { v in lang = v; I18n.setLang(v) })
    }

    func labelFor(_ key: String) -> String {
        switch key {
        case "General": return I18n.t("settings.general")
        case "Integrations": return I18n.t("settings.integrations")
        case "Repos": return I18n.t("settings.repos")
        case "About": return I18n.t("settings.about")
        default: return key
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — native macOS style
            VStack(spacing: 0) {
                ForEach(tabs, id: \.0) { (name, icon) in
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .frame(width: 16)
                            .foregroundColor(selectedTab == name ? .accentColor : .secondary)
                        Text(labelFor(name))
                            .font(.system(size: 13, weight: selectedTab == name ? .semibold : .regular))
                            .foregroundColor(selectedTab == name ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(selectedTab == name
                        ? Color(nsColor: .quaternarySystemFill)
                        : .clear)
                    .cornerRadius(5).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedTab = name }
                }
                Spacer()
            }
            .frame(width: 184).padding(.top, 12)
            .background(Color(nsColor: .controlBackgroundColor))

            // Content
            Group {
                switch selectedTab {
                case "General":         GeneralTab(lang: langBinding).id("general.\(lang)")
                case "Integrations":    IntegrationsSettingsTab().id("integrations.\(lang)")
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
        .frame(width: 680, height: 460)
        .onReceive(NotificationCenter.default.publisher(for: .showIntegrationsTab)) { _ in
            selectedTab = "Integrations"
        }
    }
}

// MARK: - Integrations

struct IntegrationsSettingsTab: View {
    @State private var results: [(any Detectable, DetectionResult)] = []
    @State private var isDetecting = false

    /// Group integrations by their nature: API Keys (balance polling) vs Editors & Tools.
    /// Editors/Tools may produce logs, subscriptions, or both — they belong together.
    /// Groups shown in order: API first (configure keys), then Dev Tools (can reference those keys)
    enum Group: String, CaseIterable {
        case apiKeys = "API"
        case editors = "Dev Tools"
        static func label(_ g: Group) -> String {
            switch g {
            case .apiKeys: return I18n.t("integrations.group_api_key")
            case .editors: return I18n.t("integrations.group_editors")
            }
        }
        var desc: String? {
            switch self {
            case .apiKeys: return I18n.t("integrations.group_api_key_desc")
            case .editors: return I18n.t("integrations.group_editors_desc")
            }
        }
    }

    func groupFor(_ integration: any Detectable) -> Group {
        // API-key-only integrations: pure balance polling, no editor/tool association
        let apiKeyOnlyIds = Set(["deepseek", "openai", "moonshot", "zhipu", "anthropic"])
        if apiKeyOnlyIds.contains(integration.id) {
            return .apiKeys
        }
        // Everything else is an editor or tool
        return .editors
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(I18n.t("integrations.title")).font(.title3).fontWeight(.semibold)
                Spacer()
                if isDetecting {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(I18n.t("integrations.redetect")) { reDetect() }.font(.caption)
                }
            }
            Text(I18n.t("integrations.desc"))
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Group.allCases, id: \.self) { group in
                        let items = results.filter { groupFor($0.0) == group }
                        if !items.isEmpty {
                            sectionHeader(Group.label(group), count: items.count)
                            if let desc = group.desc {
                                Text(desc)
                                    .font(.caption2).foregroundColor(.secondary)
                                    .padding(.bottom, 2)
                            }
                            ForEach(items, id: \.0.id) { (i, r) in
                                IntegrationRow(integration: i, detected: r,
                                               onGrant: { runDetection() })
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            runDetection()
            ApiPoller.shared.pollAll()
        }
    }

    func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
            Text("(\(count))").font(.caption2).foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    func runDetection() {
        results = IntegrationRegistry.all.map { ($0, $0.detect()) }
    }

    func reDetect() {
        isDetecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            results = IntegrationRegistry.all.map { ($0, $0.detect()) }
            isDetecting = false
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @Binding var lang: String
    @State private var coinSoundEnabled = UserDefaults.standard.bool(forKey: "coin_sound_enabled")
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

// In-memory cache for repo scans (avoids full filesystem enumeration
// every time the Repos tab is opened). Invalidated on directory add/remove.
private nonisolated(unsafe) var repoScanCache: [String: (timestamp: Date, repos: [String])] = [:]
private let repoScanCacheTTL: TimeInterval = 300 // 5 minutes

struct ReposTab: View {
    @State private var dirEntries: [DirEntry] = []
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
                        VStack(spacing: 0) {
                            // Directory row
                            HStack(spacing: 6) {
                                Image(systemName: "folder").foregroundColor(.accentColor)
                                Text(entry.path).font(.body).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if entry.isScanning {
                                    ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                                } else {
                                    Text("\(entry.repoCount)")
                                        .font(.caption2).foregroundColor(.secondary)
                                        .padding(.horizontal, 5)
                                        .background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                                }
                                Image(systemName: entry.isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.caption2).foregroundColor(.secondary)
                                    .frame(width: 12)
                                Button { deleteTarget = entry.path; showDelete = true } label: {
                                    Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 8)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) { entry.isExpanded.toggle() }
                            }

                            // Expanded repos — no checkboxes, confirmation only
                            if entry.isExpanded {
                                VStack(spacing: 2) {
                                    if entry.isScanning && entry.repos.isEmpty {
                                        HStack {
                                            ProgressView().scaleEffect(0.5)
                                            Text(I18n.t("onboarding.repos_scanning")).font(.caption2).foregroundColor(.secondary)
                                            Spacer()
                                        }.padding(.leading, 30)
                                    } else if entry.repos.isEmpty {
                                        Text(I18n.t("repos.no_repos"))
                                            .font(.caption2).foregroundColor(.secondary)
                                            .padding(.leading, 30)
                                    } else {
                                        ForEach(entry.repos, id: \.self) { name in
                                            HStack(spacing: 4) {
                                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                                    .font(.caption2).foregroundColor(.secondary)
                                                Text(name).font(.caption).lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.vertical, 2).padding(.leading, 30)
                                        }
                                    }
                                }
                                .padding(.bottom, 4)
                            }
                        }
                        .background(Color(nsColor: .quaternarySystemFill).opacity(0.4))
                        .cornerRadius(6)
                    }
                }
            }

            HStack {
                Button(action: pickDir) {
                    Label(I18n.t("repos.add"), systemImage: "plus.circle").font(.caption)
                }
                Spacer()
            }

            let totalRepos = dirEntries.reduce(0) { $0 + $1.repoCount }
            Text(String(format: I18n.t("repos.summary"), dirEntries.count, totalRepos)).font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { startScan() }
        .alert(I18n.t("repos.delete_title"), isPresented: $showDelete) {
            Button(I18n.t("repos.cancel"), role: .cancel) {}
            Button(I18n.t("repos.remove"), role: .destructive) {
                if let d = deleteTarget {
                    dirEntries.removeAll { $0.path == d }
                    repoScanCache.removeValue(forKey: d)
                    save()
                }
            }
        } message: { Text(String(format: I18n.t("repos.delete_msg"), deleteTarget ?? "")) }
    }

    // MARK: - Scanning

    private func startScan() {
        let dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        if dirs.isEmpty {
            // Under sandbox, unauthorized guessed defaults can't be read; show an empty
            // state + Add button instead of persisting/scanning unreadable directories.
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
        Task {
            for i in dirEntries.indices {
                let path = dirEntries[i].path
                if let cached = repoScanCache[path],
                   Date().timeIntervalSince(cached.timestamp) < repoScanCacheTTL {
                    // Cache hit — populate without filesystem scan
                    await MainActor.run {
                        guard i < dirEntries.count else { return }
                        dirEntries[i].repoCount = cached.repos.count
                        dirEntries[i].repos = cached.repos
                        dirEntries[i].isScanning = false
                    }
                } else {
                    await scanOne(at: i)
                }
            }
        }
    }

    private func pickDir() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = I18n.t("bookmark.grant")
        panel.message = I18n.t("bookmark.repos_message")
        panel.directoryURL = FileManager.default.realHomeDirectory
        if panel.runModal() == .OK, let url = panel.url {
            // Persist a security-scoped bookmark so access survives relaunch (sandbox).
            BookmarkManager.createAndSave(for: url)
            // Store the absolute path (see OnboardingView.pickDir for the tilde/sandbox note).
            let p = url.path
            guard !dirEntries.contains(where: { $0.path == p }) else { return }
            let entry = DirEntry(path: p)
            dirEntries.append(entry)
            save()
            let idx = dirEntries.count - 1
            Task { await scanOne(at: idx) }
            // Start monitoring the newly authorized directory without a relaunch.
            LogWatcher.shared.start()
            DataRefreshCoordinator.shared.triggerIngest()
        }
    }

    private func save() { UserDefaults.standard.set(dirEntries.map(\.path), forKey: repoDirsKey) }

    private func scanOne(at idx: Int) async {
        guard idx < dirEntries.count else { return }
        let path = dirEntries[idx].path
        await MainActor.run { dirEntries[idx].isScanning = true }
        let foundRepos = await Task.detached { () -> [String] in
            let expanded = NSString(string: path).expandingTildeInPath
            let fm = FileManager.default
            var result: [String] = []
            if fm.fileExists(atPath: expanded),
               let items = (fm.enumerator(at: URL(fileURLWithPath: expanded),
                                    includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL]) {
                for url in items {
                    let git = url.appendingPathComponent(".git")
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: git.path, isDirectory: &d), d.boolValue {
                        result.append(url.lastPathComponent)
                    }
                }
            }
            result.sort()
            return result
        }.value
        await MainActor.run {
            guard idx < dirEntries.count else { return }
            dirEntries[idx].repoCount = foundRepos.count
            dirEntries[idx].repos = foundRepos
            dirEntries[idx].isScanning = false
            // Update cache
            repoScanCache[path] = (Date(), foundRepos)
        }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIconLoader.uiImage(size: 64))
            Text(I18n.t("about.title")).font(.title).fontWeight(.bold)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0")").font(.caption).foregroundColor(.secondary)
            Text(I18n.t("about.desc")).multilineTextAlignment(.center)
            Text(I18n.t("about.privacy")).font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 16) {
                Button(I18n.t("about.privacy_link")) {
                    NSWorkspace.shared.open(URL(string: "https://xingyu.wang/apps/ai-pulse/privacy")!)
                }.buttonStyle(.link)
                Button(I18n.t("about.website")) {
                    NSWorkspace.shared.open(URL(string: "https://xingyu.wang/apps/ai-pulse/about")!)
                }.buttonStyle(.link)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
