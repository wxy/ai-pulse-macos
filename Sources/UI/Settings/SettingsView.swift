import SwiftUI
import GRDB
import AppKit

// MARK: - Main Settings

struct SettingsView: View {
    @State private var selectedTab = "Coding Tools"
    @State private var lang = I18n.getLang()
    let tabs: [(String, String)] = [
        ("Coding Tools", "hammer"), ("Repos", "folder"),
        ("Subscriptions", "creditcard"), ("Pricing", "dollarsign.circle"), ("About", "info.circle"),
    ]

    func localizedName(_ key: String) -> String {
        switch key {
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
                Picker("", selection: $lang) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .onChange(of: lang) { _, v in I18n.setLang(v) }
            }
            .frame(width: 160).padding(.top, 12)
            .background(Color(red: 0.13, green: 0.14, blue: 0.16))

            // Content
            Group {
                switch selectedTab {
                case "Coding Tools":   ToolsTab()
                case "Repos":          ReposTab()
                case "Subscriptions":  SubsTab()
                case "Pricing":        PricingTab()
                case "About":          AboutTab()
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

// MARK: - Tools

struct ToolsTab: View {
    @State private var tools: [ToolItem] = []
    struct ToolItem: Identifiable { let id = UUID(); let name: String; let path: String; let sessions: Int; var enabled: Bool }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Monitored Tools").font(.title3).fontWeight(.semibold)
            Text("AI coding tools auto-detected on your machine.").font(.caption).foregroundColor(.secondary)
            if tools.isEmpty {
                Label("No tools detected yet", systemImage: "questionmark.circle").foregroundColor(.secondary).padding(.top, 20)
            } else {
                VStack(spacing: 6) {
                    ForEach($tools) { $t in
                        HStack {
                            Toggle(isOn: $t.enabled) {}.toggleStyle(.checkbox)
                            VStack(alignment: .leading) {
                                Text(t.name).font(.body)
                                Text("\(t.path) · \(t.sessions) sessions").font(.caption2).foregroundColor(.secondary)
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
            list.append(ToolItem(name: "Claude Code", path: "~/.claude/projects/", sessions: sessions, enabled: true))
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
            Text("Git Repositories").font(.title3).fontWeight(.semibold)

            HStack(spacing: 10) {
                // Left: directories
                VStack(alignment: .leading) {
                    HStack {
                        Text("Directories").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button(action: pickDir) {
                            Label("Add", systemImage: "plus.circle").font(.caption)
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
                    Text("Repositories (\(reposForSelected.count))").font(.caption).foregroundColor(.secondary)
                    if reposForSelected.isEmpty {
                        Text("Select a directory").font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                    } else {
                        List(reposForSelected, id: \.self) { repo in
                            Label(repo, systemImage: "chevron.left.forwardslash.chevron.right").font(.caption)
                        }
                        .listStyle(.bordered)
                    }
                }.frame(minWidth: 160, idealWidth: 190, maxWidth: 210, minHeight: 140, maxHeight: 140)
            }

            Text("\(searchDirs.count) dirs · \(counts.values.reduce(0,+)) repos").font(.caption2).foregroundColor(.secondary)
        }
        .onAppear {
            load()
            refreshAll()
            if selectedDir == nil || !searchDirs.contains(selectedDir!) { selectedDir = searchDirs.first }
        }
        .onChange(of: selectedDir) { _, d in if let d, searchDirs.contains(d) { reposForSelected = scan(d) } else { reposForSelected = [] } }
        .alert("Remove Directory", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let d = deleteTarget { searchDirs.removeAll { $0 == d }; save(); refreshAll(); if selectedDir == d { selectedDir = searchDirs.first } }
            }
        } message: { Text("Stop monitoring '\(deleteTarget ?? "")'?\nIts repos will no longer be tracked.") }
    }

    private func pickDir() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Add"
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
            Text("Subscription Tools").font(.title3).fontWeight(.semibold)
            Text("Cost per line = monthly fee / net committed lines.").font(.caption).foregroundColor(.secondary)
            HStack {
                Picker("Add", selection: $pickerValue) {
                    Text("Choose preset…").tag("")
                    ForEach(presets, id: \.name) { p in
                        ForEach(p.tiers) { t in Text("\(p.name) \(t.label) ($\(String(format: "%.0f", t.fee))/mo)").tag("\(p.name)|\(t.label)|\(t.fee)") }
                    }
                }.frame(width: 280)
                Button("Add") {
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
                Text("No subscriptions added. Choose a preset above.").font(.caption).foregroundColor(.secondary).padding(.top, 10)
            } else {
                VStack(spacing: 6) {
                    ForEach(tools) { item in
                        HStack {
                            Label(item.name, systemImage: "creditcard").font(.body)
                            Spacer()
                            Text("$\(String(format: "%.2f", item.monthlyFee))/mo").foregroundColor(.secondary).font(.callout)
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
        .alert("Remove Subscription", isPresented: $showDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if let t = deleteTarget { tools.removeAll { $0.name == t.name }; deleteFromDB(t) } }
        } message: { Text("Remove '\(deleteTarget?.name ?? "")'?") }
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
            Text("Model Pricing").font(.title3).fontWeight(.semibold)
            Text("USD per million tokens.").font(.caption).foregroundColor(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow { Text("Model").font(.caption).foregroundColor(.secondary); Text("Input").font(.caption).foregroundColor(.secondary); Text("Output").font(.caption).foregroundColor(.secondary) }
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
            Text("AI Pulse").font(.title).fontWeight(.bold)
            Text("Version M1 (0.1.0)").font(.caption).foregroundColor(.secondary)
            Text("Know what AI coding really costs you.").multilineTextAlignment(.center)
            Text("All data stays on your machine.").font(.caption2).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
