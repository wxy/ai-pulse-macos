import SwiftUI
import GRDB
import AppKit

// MARK: - Main Settings

struct SettingsView: View {
    @State private var selectedTab = "General"
    @State private var lang = I18n.getLang()
    let tabs: [(String, String)] = [
        ("General", "gear"), ("API Keys", "key"), ("Coding Tools", "hammer"), ("Repos", "folder"),
        ("Subscriptions", "creditcard"), ("Pricing", "dollarsign.circle"), ("About", "info.circle"),
    ]

    /// Custom binding that calls I18n.setLang() synchronously on every set,
    /// so the language change takes effect BEFORE SwiftUI re-evaluates the
    /// body (avoiding the `.onChange` race with `.id()`-based view recreation).
    var langBinding: Binding<String> {
        Binding(get: { lang }, set: { v in lang = v; I18n.setLang(v) })
    }

    func localizedName(_ key: String) -> String {
        switch key {
        case "General": return I18n.t("settings.general")
        case "API Keys": return I18n.t("settings.api_keys")
        case "Coding Tools": return I18n.t("settings.coding_tools")
        case "Repos": return I18n.t("settings.repos")
        case "Subscriptions": return I18n.t("settings.subscriptions")
        case "Pricing": return I18n.t("settings.pricing")
        case "About": return I18n.t("settings.about")
        default: return key
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(spacing: 2) {
                ForEach(tabs, id: \.0) { (name, icon) in
                    Text(localizedName(name))
                        .font(.system(size: 12, weight: selectedTab == name ? .semibold : .regular))
                        .foregroundColor(selectedTab == name ? .white : Color.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(selectedTab == name ? Color.white.opacity(0.1) : .clear)
                        .cornerRadius(4).padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedTab = name }
                }
                Spacer()
            }
            .frame(width: 160).padding(.top, 12)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            // Content — each tab has .id(lang) so it re-renders immediately
            // when the language picker changes (no tab-switch needed).
            Group {
                switch selectedTab {
                case "General":         GeneralTab(lang: langBinding).id("general.\(lang)")
                case "API Keys":        ApiKeysTab().id("apikeys.\(lang)")
                case "Coding Tools":   ToolsTab().id("tools.\(lang)")
                case "Repos":          ReposTab().id("repos.\(lang)")
                case "Subscriptions":  SubsTab().id("subs.\(lang)")
                case "Pricing":        PricingTab().id("pricing.\(lang)")
                case "About":          AboutTab().id("about.\(lang)")
                default: EmptyView()
                }
            }
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 640, height: 420)
    }
}

// MARK: - General

struct GeneralTab: View {
    @Binding var lang: String
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

            ScrollView {
                VStack(spacing: 5) {
                    ForEach(ProviderRegistry.all, id: \.id) { p in
                        HStack(spacing: 0) {
                            // Column 1: Provider name (fixed, all rows aligned)
                            Text(p.name).font(.callout).frame(width: nameW, alignment: .leading)

                            if p.canFetchBalance {
                                // Column 2: Key input or mask
                                if masks[p.id] == true {
                                    Text("••••••••")
                                        .font(.callout).foregroundColor(.secondary)
                                        .frame(width: keyW, alignment: .leading)

                                    Button(I18n.t("apikeys.change")) {
                                        masks[p.id] = false
                                        keyInputs[p.id] = ""
                                    }.frame(width: btnW)
                                } else {
                                    TextField(I18n.t("apikeys.placeholder"), text: Binding(
                                        get: { keyInputs[p.id] ?? "" },
                                        set: { keyInputs[p.id] = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: keyW)

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

                                // Column 4: Balance
                                balanceView(for: p.id).frame(width: balW, alignment: .leading)
                            } else {
                                // No balance API — note spans the remaining 3 columns
                                Text(I18n.t(p.noBalanceNoteKey ?? "apikeys.no_balance"))
                                    .font(.caption2).foregroundColor(.secondary)
                                    .frame(width: restW, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear {
            for p in ProviderRegistry.all {
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
        let ccDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        if FileManager.default.fileExists(atPath: ccDir.path) {
            let sessions = (try? FileManager.default.contentsOfDirectory(atPath: ccDir.path))?.count ?? 0
            list.append(ToolItem(name: I18n.t("tools.claude_code"), path: "~/.claude/projects/", sessions: sessions, enabled: true))
        }
        tools = list
    }
}

// MARK: - Repos

private let repoDirsKey = "repo_search_dirs"
private var repoCache: [String: [String]] = [:]

struct ReposTab: View {
    @State private var searchDirs: [String] = []
    @State private var selectedDir: String? = nil
    @State private var reposForSelected: [String] = []
    @State private var counts: [String: Int] = [:]
    @State private var deleteTarget: String? = nil
    @State private var showDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18n.t("repos.title")).font(.title3).fontWeight(.semibold)

            HStack(spacing: 10) {
                // Left: directories
                VStack(alignment: .leading) {
                    HStack {
                        Text(I18n.t("repos.directories")).font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(action: pickDir) {
                            Label(I18n.t("repos.add"), systemImage: "plus.circle").font(.caption)
                        }
                    }
                    List(selection: $selectedDir) {
                        ForEach(searchDirs, id: \.self) { dir in
                            HStack {
                                Image(systemName: "folder").foregroundColor(.accentColor)
                                Text(dir).font(.caption).lineLimit(1)
                                Spacer()
                                Text("\(counts[dir, default: 0])").font(.caption2).foregroundColor(.secondary)
                                    .padding(.horizontal, 5).background(Capsule().fill(Color(nsColor: .quaternarySystemFill)))
                                Button { deleteTarget = dir; showDelete = true } label: {
                                    Image(systemName: "xmark.circle").font(.caption).foregroundColor(.secondary)
                                }.buttonStyle(.plain)
                            }
                            .padding(.vertical, 1).tag(dir)
                        }
                    }
                    .listStyle(.bordered).frame(minWidth: 200, idealWidth: 220, maxWidth: 240, minHeight: 140, maxHeight: 140)
                }

                // Right: repos
                VStack(alignment: .leading) {
                    Text("\(I18n.t("repos.repositories")) (\(reposForSelected.count))").font(.caption).foregroundColor(.secondary)
                    if reposForSelected.isEmpty {
                        Text(I18n.t("repos.select_dir")).font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                    } else {
                        List(reposForSelected, id: \.self) { repo in
                            Label(repo, systemImage: "chevron.left.forwardslash.chevron.right").font(.caption)
                        }
                        .listStyle(.bordered)
                    }
                }.frame(minWidth: 160, idealWidth: 190, maxWidth: 210, minHeight: 140, maxHeight: 140)
            }

            Text(String(format: I18n.t("repos.summary"), searchDirs.count, counts.values.reduce(0,+))).font(.caption2).foregroundColor(.secondary)
        }
        .onAppear {
            load()
            refreshAll()
            if selectedDir == nil || !searchDirs.contains(selectedDir!) { selectedDir = searchDirs.first }
        }
        .onChange(of: selectedDir) { _, d in if let d, searchDirs.contains(d) { reposForSelected = scan(d) } else { reposForSelected = [] } }
        .alert(I18n.t("repos.delete_title"), isPresented: $showDelete) {
            Button(I18n.t("repos.cancel"), role: .cancel) {}
            Button(I18n.t("repos.remove"), role: .destructive) {
                if let d = deleteTarget { searchDirs.removeAll { $0 == d }; save(); refreshAll(); if selectedDir == d { selectedDir = searchDirs.first } }
            }
        } message: { Text(String(format: I18n.t("repos.delete_msg"), deleteTarget ?? "")) }
    }

    private func pickDir() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = I18n.t("repos.add")
        if panel.runModal() == .OK, let url = panel.url {
            let p = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            if !searchDirs.contains(p) { searchDirs.append(p); save(); refreshAll(); if selectedDir == nil { selectedDir = p } }
        }
    }
    private func load() {
        if let s = UserDefaults.standard.stringArray(forKey: repoDirsKey), !s.isEmpty { searchDirs = s }
        if searchDirs.isEmpty { searchDirs = ["~/dev", "~/projects", "~/code"]; save() }
    }
    private func save() { UserDefaults.standard.set(searchDirs, forKey: repoDirsKey) }
    private func refreshAll() { counts.removeAll(); for d in searchDirs { counts[d] = scan(d).count } }
    private func scan(_ dir: String) -> [String] {
        if let cached = repoCache[dir] { return cached }
        let expanded = NSString(string: dir).expandingTildeInPath; let fm = FileManager.default
        guard fm.fileExists(atPath: expanded),
              let e = fm.enumerator(at: URL(fileURLWithPath: expanded), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [String] = []
        for case let url as URL in e {
            let git = url.appendingPathComponent(".git"); var d: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &d), d.boolValue { found.append(url.lastPathComponent); e.skipDescendants() }
        }
        let sorted = found.sorted(); repoCache[dir] = sorted; return sorted
    }
}

// MARK: - Subscriptions

struct SubsTab: View {
    @State private var tools: [SubItem] = []
    @State private var pickerValue = ""
    @State private var deleteTarget: SubItem? = nil
    @State private var showDelete = false
    @State private var dbError: String?
    struct SubItem: Identifiable, Equatable { var id: String { name }; let name: String; let monthlyFee: Double; let currency: String }
    struct Preset { let name: String; let tiers: [Tier] }
    struct Tier: Identifiable { var id: String { label }; let label: String; let fee: Double }
    let presets: [Preset] = [
        Preset(name: "Cursor",  tiers: [Tier(label: "Pro", fee: 20), Tier(label: "Business", fee: 40)]),
        Preset(name: "Copilot", tiers: [Tier(label: "Individual", fee: 10), Tier(label: "Business", fee: 19), Tier(label: "Enterprise", fee: 39)]),
        Preset(name: "Windsurf", tiers: [Tier(label: "Pro", fee: 15)]),
        Preset(name: "Codeium", tiers: [Tier(label: "Individual", fee: 15), Tier(label: "Teams", fee: 35)]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("subs.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("subs.desc")).font(.caption).foregroundColor(.secondary)
            HStack {
                Picker(I18n.t("subs.add"), selection: $pickerValue) {
                    Text(I18n.t("subs.choose")).tag("")
                    ForEach(presets, id: \.name) { p in
                        ForEach(p.tiers) { t in Text("\(p.name) \(t.label) ($\(String(format: "%.0f", t.fee))\(I18n.t("subs.per_month")))").tag("\(p.name)|\(t.label)|\(t.fee)") }
                    }
                }.frame(width: 280)
                Button(I18n.t("subs.add")) {
                    let parts = pickerValue.components(separatedBy: "|")
                    guard parts.count == 3, let fee = Double(parts[2]) else { return }
                    let name = "\(parts[0]) \(parts[1])"
                    if tools.contains(where: { $0.name == name }) { pickerValue = ""; return }
                    let item = SubItem(name: name, monthlyFee: fee, currency: "USD")
                    tools.append(item); saveToDB(item); pickerValue = ""
                }.disabled(pickerValue.isEmpty)
            }
            if let err = dbError { Text(err).font(.caption2).foregroundColor(.red) }
            if tools.isEmpty {
                Text(I18n.t("subs.empty")).font(.caption).foregroundColor(.secondary).padding(.top, 10)
            } else {
                VStack(spacing: 6) {
                    ForEach(tools) { item in
                        HStack {
                            Label(item.name, systemImage: "creditcard").font(.body)
                            Spacer()
                            Text("$\(String(format: "%.2f", item.monthlyFee))\(I18n.t("subs.per_month"))").foregroundColor(.secondary).font(.callout)
                            Button { deleteTarget = item; showDelete = true } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }.buttonStyle(.plain)
                        }
                        .padding(10).background(Color(nsColor: .quaternarySystemFill)).cornerRadius(8)
                    }
                }
            }
        }
        .onAppear { loadFromDB() }
        .alert(I18n.t("subs.delete_title"), isPresented: $showDelete) {
            Button(I18n.t("repos.cancel"), role: .cancel) {}
            Button(I18n.t("repos.remove"), role: .destructive) { if let t = deleteTarget { tools.removeAll { $0.name == t.name }; deleteFromDB(t) } }
        } message: { Text(String(format: I18n.t("subs.delete_msg"), deleteTarget?.name ?? "")) }
    }

    private func saveToDB(_ item: SubItem) {
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: "INSERT OR REPLACE INTO subscription_tool (id, name, monthly_fee, currency) VALUES (?,?,?,?)",
                        arguments: [item.name, item.name, item.monthlyFee, item.currency])
                }
                await MainActor.run { dbError = nil }
            } catch { await MainActor.run { dbError = "Save: \(error.localizedDescription)" } }
        }
    }
    private func deleteFromDB(_ item: SubItem) {
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: "DELETE FROM subscription_tool WHERE id=?", arguments: [item.name])
                }
            } catch { await MainActor.run { dbError = "Delete: \(error.localizedDescription)" } }
        }
    }
    private func loadFromDB() {
        Task {
            do {
                let rows = try await AppDatabase.shared.read { db in
                    try Row.fetchAll(db, sql: "SELECT name, monthly_fee, currency FROM subscription_tool")
                }
                var loaded = rows.map { SubItem(name: $0["name"] ?? "", monthlyFee: $0["monthly_fee"] ?? 0, currency: $0["currency"] ?? "USD") }
                if loaded.isEmpty {
                    let preset1 = SubItem(name: "Cursor Pro", monthlyFee: 20, currency: "USD")
                    let preset2 = SubItem(name: "GitHub Copilot", monthlyFee: 10, currency: "USD")
                    loaded = [preset1, preset2]
                    saveToDB(preset1); saveToDB(preset2)
                }
                await MainActor.run { tools = loaded; dbError = nil }
            } catch { await MainActor.run { dbError = "Load: \(error.localizedDescription)" } }
        }
    }
}

// MARK: - Pricing

struct PricingTab: View {
    struct Row: Identifiable { let id = UUID(); let name: String; let input: Double; let output: Double }
    let models: [Row] = [
        Row(name: "DeepSeek V4 Pro", input: 0.5, output: 2.2),
        Row(name: "Claude Sonnet 4", input: 3.0, output: 15.0),
        Row(name: "GPT-4o", input: 2.5, output: 10.0),
        Row(name: "Gemini 2.5 Pro", input: 1.25, output: 10.0),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("pricing.title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("pricing.desc")).font(.caption).foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { Text(I18n.t("pricing.model")).font(.caption).foregroundColor(.secondary); Text(I18n.t("pricing.input")).font(.caption).foregroundColor(.secondary); Text(I18n.t("pricing.output")).font(.caption).foregroundColor(.secondary) }
                ForEach(models) { m in
                    GridRow {
                        Text(m.name).font(.callout)
                        Text("$\(String(format: "%.2f", m.input))").monospacedDigit()
                        Text("$\(String(format: "%.2f", m.output))").monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("🤖").font(.system(size: 48))
            Text(I18n.t("about.title")).font(.title).fontWeight(.bold)
            Text(I18n.t("about.version")).font(.caption).foregroundColor(.secondary)
            Text(I18n.t("about.desc")).multilineTextAlignment(.center)
            Text(I18n.t("about.privacy")).font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
