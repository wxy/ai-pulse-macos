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
            .frame(width: 160).padding(.top, 12)
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
    }
}

// MARK: - Integrations

struct IntegrationsSettingsTab: View {
    @State private var results: [(any Detectable, DetectionResult)] = []
    @State private var isDetecting = false

    /// Classify an integration by its primary CostSource kind.
    enum Group: String, CaseIterable {
        case apiKey = "API Key"
        case subscription = "Subscription"
        case log = "Log-based"
        static func label(_ g: Group) -> String {
            switch g {
            case .apiKey:       return I18n.t("integrations.group_api_key")
            case .subscription: return I18n.t("integrations.group_subscription")
            case .log:          return I18n.t("integrations.group_log")
            }
        }
    }

    func groupFor(_ integration: any Detectable) -> Group {
        let cs = integration.costSources
        if cs.contains(where: { if case .apiKey = $0.kind { return true }; return false }) {
            return .apiKey
        }
        if cs.contains(where: { if case .subscription = $0.kind { return true }; return false }) {
            return .subscription
        }
        return .log
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
                            ForEach(items, id: \.0.id) { (i, r) in
                                IntegrationRow(integration: i, detected: r,
                                               onGrant: { runDetection() })
                            }
                        }
                    }
                }
            }
        }
        .onAppear { runDetection() }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("general.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("general.desc")).font(.caption).foregroundColor(.secondary)

            HStack {
                Text(I18n.t("general.language_label"))
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: $lang) {
                    Text(I18n.t("settings.language_zh")).tag("zh")
                    Text(I18n.t("settings.language_en")).tag("en")
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
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

            Text(I18n.t("general.rerun_welcome_desc"))
                .font(.caption).foregroundColor(.secondary)
            Button(I18n.t("general.rerun_welcome")) {
                UserDefaults.standard.removeObject(forKey: "onboarding_completed")
                // Re-open onboarding
                if let w = OnboardingWindowManager.shared.window { w.close() }
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
                w.title = "AI Pulse — Welcome"
                w.contentView = NSHostingView(rootView: OnboardingView())
                w.center(); w.makeKeyAndOrderFront(nil); w.isReleasedWhenClosed = false
                OnboardingWindowManager.shared.window = w
            }
        }
    }
}

// MARK: - API Keys

struct ApiKeysTab: View {
    @State private var keyInputs: [String: String] = [:]
    @State private var masks: [String: Bool] = [:]
    @State private var cachedBalances: [String: CachedBalance] = [:]

    // Fixed column widths so rows with/without balance API align identically
    private let nameW: CGFloat   = 72
    private let keyW: CGFloat    = 148
    private let btnW: CGFloat    = 44
    private let balW: CGFloat    = 110
    // Total width after the name column (key + btn + balance)
    private var restW: CGFloat   { keyW + btnW + balW }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("apikeys.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("apikeys.desc")).font(.caption).foregroundColor(.secondary)

            let balanceProviders = ProviderRegistry.all.filter(\.canFetchBalance)

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(balanceProviders, id: \.id) { p in
                        HStack(spacing: 0) {
                            Text(p.name).font(.callout).frame(width: nameW, alignment: .leading)

                            if masks[p.id] == true {
                                Text("••••••••")
                                    .font(.callout).foregroundColor(.secondary)
                                    .frame(width: keyW, alignment: .leading)

                                Button(I18n.t("apikeys.change")) {
                                    masks[p.id] = false
                                    keyInputs[p.id] = ""
                                }.frame(width: btnW)
                            } else {
PasteableTextField(
                                    text: Binding(
                                        get: { keyInputs[p.id] ?? "" },
                                        set: { keyInputs[p.id] = $0 }
                                    ),
                                    placeholder: I18n.t("apikeys.placeholder")
                                )
                                    .frame(width: keyW, height: 22)

                                Button(I18n.t("apikeys.save")) {
                                    let k = keyInputs[p.id] ?? ""
                                    if k.isEmpty {
                                        ApiKeyManager.shared.delete(p.id)
                                        masks[p.id] = false
                                    } else {
                                        ApiKeyManager.shared.set(p.id, key: k)
                                        masks[p.id] = true
                                        keyInputs[p.id] = ""
                                        ApiPoller.shared.fetchNow(providerId: p.id)
                                    }
                                    refreshCache()
                                }
                                .disabled((keyInputs[p.id] ?? "").isEmpty)
                                .frame(width: btnW)
                            }

                            balanceView(for: p.id).frame(width: balW, alignment: .leading)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear {
            for p in ProviderRegistry.all where p.canFetchBalance {
                if let saved = ApiKeyManager.shared.get(p.id), !saved.isEmpty {
                    masks[p.id] = true
                    keyInputs[p.id] = ""
                } else {
                    masks[p.id] = false
                    keyInputs[p.id] = ""
                }
            }
            refreshCache()
        }
    }

    @ViewBuilder
    private func balanceView(for providerId: String) -> some View {
        if let cb = cachedBalances[providerId] {
            if let err = cb.error {
                Text(err).font(.caption2).foregroundColor(.orange).lineLimit(1)
            } else if let b = cb.balances.first {
                Text("\(b.currency) \(String(format: "%.2f", b.totalBalance))")
                    .font(.caption2).foregroundColor(.secondary).monospacedDigit()
            } else {
                Text("--").font(.caption2).foregroundColor(.secondary)
            }
        } else {
            Text("--").font(.caption2).foregroundColor(.secondary)
        }
    }

    private func refreshCache() {
        var cb: [String: CachedBalance] = [:]
        for p in ProviderRegistry.all where p.canFetchBalance {
            if let c = ApiPoller.shared.cachedBalance(for: p.id) { cb[p.id] = c }
        }
        cachedBalances = cb
    }
}

// MARK: - Tools

struct ToolsTab: View {
    @State private var tools: [ToolItem] = []
    struct ToolItem: Identifiable { let id = UUID(); let name: String; let path: String; let sessions: Int; var enabled: Bool }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("tools.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("tools.desc")).font(.caption).foregroundColor(.secondary)
            if tools.isEmpty {
                Label(I18n.t("tools.no_tools"), systemImage: "questionmark.circle").foregroundColor(.secondary).padding(.top, 20)
            } else {
                VStack(spacing: 6) {
                    ForEach($tools) { $t in
                        HStack {
                            Toggle(isOn: $t.enabled) {}.toggleStyle(.checkbox)
                            VStack(alignment: .leading) {
                                Text(t.name).font(.body)
                                Text("\(t.path) · \(t.sessions) \(I18n.t("tools.sessions"))").font(.caption2).foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10).background(Color(nsColor: .quaternarySystemFill)).cornerRadius(8)
                    }
                }
            }
        }
        .onAppear { detect() }
    }
    private func detect() {
        var list: [ToolItem] = []
        let ccDir = FileManager.default.realHomeDirectory.appendingPathComponent(".claude/projects")
        if FileManager.default.fileExists(atPath: ccDir.path) {
            let sessions = (try? FileManager.default.contentsOfDirectory(atPath: ccDir.path))?.count ?? 0
            list.append(ToolItem(name: I18n.t("tools.claude_code"), path: "~/.claude/projects/", sessions: sessions, enabled: true))
        }
        tools = list
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

// MARK: - Subscriptions

struct SubsTab: View {
    @State private var selections: [String: String] = [:] // bundleId → tier label
    @State private var dbError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("subs.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("subs.desc")).font(.caption).foregroundColor(.secondary)

            let detected = SubscriptionRegistry.tools.filter(\.installed)
            let notDetected = SubscriptionRegistry.tools.filter { !$0.installed }

            if detected.isEmpty && notDetected.isEmpty {
                Text(I18n.t("subs.empty")).font(.caption).foregroundColor(.secondary).padding(.top, 10)
            }

            // Detected tools — pick a tier
            ForEach(detected) { tool in
                HStack {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                    Text(tool.name).font(.body).frame(width: 180, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { selections[tool.name] ?? "" },
                        set: { v in selections[tool.name] = v; save(tool: tool, tierLabel: v) }
                    )) {
                        Text(I18n.t("subs.choose")).tag("")
                        ForEach(tool.tiers) { t in
                            Text("\(t.label) ($\(String(format: "%.0f", t.fee))\(I18n.t("subs.per_month")))").tag(t.label)
                        }
                    }.frame(width: 220)
                }
                .padding(.vertical, 4)
            }

            // Not installed — greyed out
            if !notDetected.isEmpty && !detected.isEmpty {
                Divider().padding(.vertical, 4)
            }
            ForEach(notDetected) { tool in
                HStack {
                    Image(systemName: "questionmark.circle").foregroundColor(.secondary)
                    Text(tool.name).font(.body).foregroundColor(.secondary).frame(width: 180, alignment: .leading)
                    Text(I18n.t("subs.not_installed")).font(.caption).foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            if let err = dbError { Text(err).font(.caption2).foregroundColor(.red) }
        }
        .onAppear {
            // Restore saved selections from DB
            Task {
                do {
                    // Process Row values inside the read closure so only
                    // Sendable types cross isolation boundaries (Row is not
                    // Sendable in Swift 6 strict mode).
                    let map: [String: String] = try await AppDatabase.shared.read { db in
                        let rows = try Row.fetchAll(db, sql: "SELECT id, name, monthly_fee, currency FROM subscription_tool")
                        var map = [String: String]()
                        for r in rows {
                            let name: String = r["name"] ?? ""
                            if let tool = SubscriptionRegistry.tools.first(where: { name.hasPrefix($0.name) }) {
                                let tierLabel = String(name.dropFirst(tool.name.count + 1))
                                if tool.tiers.contains(where: { $0.label == tierLabel }) {
                                    map[tool.name] = tierLabel
                                }
                            }
                        }
                        return map
                    }
                    await MainActor.run { selections = map; dbError = nil }
                } catch {
                    await MainActor.run { dbError = "Load: \(error.localizedDescription)" }
                }
            }
        }
    }

    private func save(tool: SubscriptionTool, tierLabel: String) {
        let itemName = "\(tool.name) \(tierLabel)"
        guard let tier = tool.tiers.first(where: { $0.label == tierLabel }) else { return }
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO subscription_tool (id, name, monthly_fee, currency)
                        VALUES (?, ?, ?, ?)
                        """, arguments: [tool.name, itemName, tier.fee, tier.currency])
                }
                await MainActor.run { dbError = nil }
            } catch { await MainActor.run { dbError = "Save: \(error.localizedDescription)" } }
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
