import SwiftUI
import GRDB
import AppKit

struct SettingsView: View {
    @State private var selectedTab = "Tools"

    let tabs = [
        ("Tools", "hammer"),
        ("Repos", "folder"),
        ("Subscriptions", "creditcard"),
        ("Pricing", "dollarsign.circle"),
        ("About", "info.circle"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(tabs, id: \.0) { (name, icon) in
                    Button(action: { selectedTab = name }) {
                        HStack {
                            Image(systemName: icon).frame(width: 20)
                            Text(name)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selectedTab == name ? Color.accentColor : Color.clear)
                        .foregroundColor(selectedTab == name ? .white : .primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 140)
            .background(Color(nsColor: .windowBackgroundColor))

            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)

            Group {
                if selectedTab == "Tools" { MonitoredToolsView() }
                else if selectedTab == "Repos" { GitReposView() }
                else if selectedTab == "Subscriptions" { SubscriptionToolsView() }
                else if selectedTab == "Pricing" { PricingView() }
                else if selectedTab == "About" { AboutView() }
            }
            .id(selectedTab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
        }
        .frame(width: 600, height: 380)
    }
}

// MARK: - Tools

struct MonitoredToolsView: View {
    @State private var enabledTools: [ToolInfo] = []
    struct ToolInfo: Identifiable, Equatable {
        let id = UUID(); let name: String; let path: String; var enabled: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monitored AI Tools").font(.headline)
            if enabledTools.isEmpty {
                Text("No tools detected. Start using Claude Code or aider to auto-detect.").font(.caption).foregroundColor(.secondary)
            } else {
                List($enabledTools) { $tool in
                    Toggle(isOn: $tool.enabled) {
                        VStack(alignment: .leading) {
                            Text(tool.name).font(.body)
                            Text(tool.path).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(height: 120)
            }
        }
        .onAppear { detectTools() }
    }

    private func detectTools() {
        var tools: [ToolInfo] = []
        let ccDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        if FileManager.default.fileExists(atPath: ccDir.path) {
            tools.append(ToolInfo(name: "Claude Code", path: "~/.claude/projects/", enabled: true))
        }
        // Check for aider in common repos
        let home = FileManager.default.homeDirectoryForCurrentUser
        for dir in ["dev", "projects", "code"] {
            let url = home.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let e = FileManager.default.enumerator(at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let repo as URL in e {
                    let aiderFile = repo.appendingPathComponent(".aider.llm.history")
                    if FileManager.default.fileExists(atPath: aiderFile.path) {
                        if !tools.contains(where: { $0.name == "aider" }) {
                            tools.append(ToolInfo(name: "aider", path: "(found in repos)", enabled: true))
                        }
                        e.skipDescendants()
                    }
                }
            }
        }
        enabledTools = tools
    }
}

// MARK: - Repos

private let repoDirsKey = "repo_search_dirs"

struct GitReposView: View {
    @State private var searchDirs: [String] = []
    @State private var selectedDir: String? = nil
    @State private var reposForDir: [String] = []
    @State private var dirRepoCounts: [String: Int] = [:]
    @State private var showDeleteAlert = false
    @State private var dirToDelete: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Git Repositories").font(.headline)
            HStack(spacing: 8) {
                // Directory list
                VStack(alignment: .leading) {
                    Text("Directories").font(.caption).foregroundColor(.secondary)
                    List(selection: $selectedDir) {
                        ForEach(searchDirs, id: \.self) { dir in
                            HStack {
                                Text(dir).font(.caption)
                                Spacer()
                                Text("\(dirRepoCounts[dir, default: 0])").font(.caption).foregroundColor(.secondary)
                            }
                            .tag(dir)
                            .contextMenu {
                                Button("Remove") { dirToDelete = dir; showDeleteAlert = true }
                            }
                        }
                    }
                    .listStyle(.bordered)
                    .frame(height: 100)
                    .onChange(of: selectedDir) { _, newDir in
                        if let d = newDir { reposForDir = scanRepos(in: d) }
                    }
                }
                .frame(maxWidth: .infinity)

                // Repo list for selected dir
                VStack(alignment: .leading) {
                    Text(selectedDir != nil ? "Repos (\(reposForDir.count))" : "Repos").font(.caption).foregroundColor(.secondary)
                    if reposForDir.isEmpty {
                        Text(selectedDir != nil ? "No repos found." : "Select a directory.").font(.caption).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center).padding(.top, 30)
                    } else {
                        List(reposForDir, id: \.self) { repo in
                            Text(repo).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                        .listStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HStack {
                Button("Add Directory…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Select"
                    if panel.runModal() == .OK, let url = panel.url {
                        let path = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                        if !searchDirs.contains(path) { searchDirs.append(path); save(); rescanAll() }
                    }
                }
            }

            Text("\(reposForDir.count) repos · \(searchDirs.count) directories").font(.caption2).foregroundColor(.secondary)
        }
        .onAppear { load(); rescanAll(); if selectedDir == nil { selectedDir = searchDirs.first } }
        .alert("Remove Directory", isPresented: $showDeleteAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let d = dirToDelete { searchDirs.removeAll { $0 == d }; save(); rescanAll(); if selectedDir == d { selectedDir = searchDirs.first } }
            }
        } message: { Text("Stop monitoring repos in '\(dirToDelete ?? "")'?") }
    }

    private func load() {
        if let saved = UserDefaults.standard.stringArray(forKey: repoDirsKey), !saved.isEmpty { searchDirs = saved }
        if searchDirs.isEmpty { searchDirs = ["~/dev", "~/projects", "~/code"] }
    }
    private func save() { UserDefaults.standard.set(searchDirs, forKey: repoDirsKey) }
    private func rescanAll() {
        dirRepoCounts.removeAll()
        for dir in searchDirs { dirRepoCounts[dir] = scanRepos(in: dir).count }
        if let d = selectedDir, searchDirs.contains(d) { reposForDir = scanRepos(in: d) }
    }
    private func scanRepos(in dir: String) -> [String] {
        let expanded = NSString(string: dir).expandingTildeInPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: expanded),
              let e = fm.enumerator(at: URL(fileURLWithPath: expanded),
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [String] = []
        for case let url as URL in e {
            let git = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: git.path, isDirectory: &isDir), isDir.boolValue { found.append(url.lastPathComponent); e.skipDescendants() }
        }
        return found.sorted()
    }
}

// MARK: - Subscriptions

struct SubscriptionToolsView: View {
    @State private var tools: [SubTool] = []
    @State private var newName = ""
    @State private var newFee = ""

    struct SubTool: Identifiable, Codable {
        var id: String { name }
        let name: String
        let monthlyFee: Double
        let currency: String
    }

    let presets: [(name: String, tiers: [(label: String, fee: Double)])] = [
        ("Cursor",    [("Pro", 20), ("Business", 40)]),
        ("Copilot",   [("Individual", 10), ("Business", 19), ("Enterprise", 39)]),
        ("Windsurf",  [("Pro", 15)]),
        ("Codeium",   [("Individual", 15), ("Teams", 35)]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscription Tools").font(.headline)
            Text("Cost per line = monthly fee / net lines committed.")
                .font(.caption).foregroundColor(.secondary)

            HStack {
                Picker("Add:", selection: $newName) {
                    Text("Choose preset…").tag("")
                    ForEach(presets, id: \.name) { p in
                        ForEach(p.tiers, id: \.label) { t in
                            Text("\(p.name) \(t.label) ($\(String(format: "%.0f", t.fee))/mo)").tag("\(p.name)|\(t.label)|\(t.fee)")
                        }
                    }
                }
                .frame(width: 260)
                Button("Add") {
                    let parts = newName.components(separatedBy: "|")
                    guard parts.count == 3, let fee = Double(parts[2]) else { return }
                    let name = "\(parts[0]) \(parts[1])"
                    guard !tools.contains(where: { $0.name == name }) else { newName = ""; return }
                    let tool = SubTool(name: name, monthlyFee: fee, currency: "USD")
                    tools.append(tool); saveToDB(tool); newName = ""
                }
                .disabled(newName.isEmpty)
            }

            List {
                ForEach(tools) { tool in
                    HStack {
                        Text(tool.name)
                        Spacer()
                        Text("$\(String(format: "%.2f", tool.monthlyFee))/mo").foregroundColor(.secondary)
                        Button { deleteFromDB(tool); tools.removeAll { $0.name == tool.name } } label: {
                            Image(systemName: "trash").font(.caption)
                        }.buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .frame(height: 100)
        }
        .onAppear { loadFromDB() }
    }

    private func saveToDB(_ tool: SubTool) {
        Task {
            try? await AppDatabase.shared.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO subscription_tool (id, name, monthly_fee, currency) VALUES (?,?,?,?)",
                    arguments: [tool.name, tool.name, tool.monthlyFee, tool.currency])
            }
        }
    }
    private func deleteFromDB(_ tool: SubTool) {
        Task { try? await AppDatabase.shared.write { db in try db.execute(sql: "DELETE FROM subscription_tool WHERE id=?", arguments: [tool.name]) } }
    }
    private func loadFromDB() {
        Task {
            let rows: [Row]? = try? await AppDatabase.shared.read { db in try Row.fetchAll(db, sql: "SELECT name, monthly_fee, currency FROM subscription_tool") }
            var loaded = rows?.map { SubTool(name: $0["name"] ?? "", monthlyFee: $0["monthly_fee"] ?? 0, currency: $0["currency"] ?? "USD") } ?? []
            if loaded.isEmpty {
                for preset in [SubTool(name: "Cursor Pro", monthlyFee: 20, currency: "USD"),
                               SubTool(name: "GitHub Copilot", monthlyFee: 10, currency: "USD")] {
                    saveToDB(preset); loaded.append(preset)
                }
            }
            await MainActor.run { tools = loaded }
        }
    }
}

// MARK: - Pricing

struct PricingRow: Identifiable { let id = UUID(); let name: String; let provider: String; let input: Double; let output: Double }

struct PricingView: View {
    let models: [PricingRow] = [
        PricingRow(name: "DeepSeek V4 Pro", provider: "deepseek", input: 0.5, output: 2.2),
        PricingRow(name: "DeepSeek Chat (V3)", provider: "deepseek", input: 0.27, output: 1.1),
        PricingRow(name: "Claude Sonnet 4", provider: "anthropic", input: 3.0, output: 15.0),
        PricingRow(name: "GPT-4o", provider: "openai", input: 2.5, output: 10.0),
        PricingRow(name: "Gemini 2.5 Pro", provider: "google", input: 1.25, output: 10.0),
    ]
    var body: some View {
        VStack(alignment: .leading) {
            Text("Model Pricing ($/M tokens)").font(.headline).padding(.bottom, 4)
            List(models) { m in
                HStack {
                    Text(m.name).frame(width: 150, alignment: .leading)
                    Text(m.provider).frame(width: 80, alignment: .leading).foregroundColor(.secondary)
                    Text("in: $\(String(format: "%.2f", m.input))").frame(width: 80, alignment: .trailing)
                    Text("out: $\(String(format: "%.2f", m.output))").frame(width: 80, alignment: .trailing)
                }.font(.caption)
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("🤖").font(.system(size: 48))
            Text("AI Pulse").font(.title).fontWeight(.bold)
            Text("Version 0.1.0 (M1)").font(.caption).foregroundColor(.secondary)
            Text("Know what AI coding really costs you — per line, per project, per tool.")
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Text("All data processed locally. Nothing leaves your machine.").font(.caption).foregroundColor(.secondary)
        }
    }
}
