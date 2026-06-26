import SwiftUI
import GRDB
import AppKit

struct SettingsView: View {
    @State private var selectedTab = "tools"

    enum Tab: String, CaseIterable {
        case tools = "Tools"
        case repos = "Repos"
        case subscriptions = "Subscriptions"
        case pricing = "Pricing"
        case about = "About"
        var icon: String {
            switch self {
            case .tools: return "hammer"
            case .repos: return "folder"
            case .subscriptions: return "creditcard"
            case .pricing: return "dollarsign.circle"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView(sidebar: {
            List(Tab.allCases, id: \.rawValue, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon).tag(tab.rawValue)
            }
            .navigationSplitViewColumnWidth(120)
        }, detail: {
            switch selectedTab {
            case "tools":       MonitoredToolsView()
            case "repos":       GitReposView()
            case "subscriptions": SubscriptionToolsView()
            case "pricing":     PricingView()
            case "about":       AboutView()
            default:            Text("Select a tab").foregroundColor(.secondary)
            }
        })
        .frame(width: 580, height: 380)
    }
}

// MARK: - Tools

struct MonitoredToolsView: View {
    @State private var claudeCodeEnabled = true
    var body: some View {
        VStack(alignment: .leading) {
            Text("Monitored AI Tools").font(.headline)
            HStack { Text("Claude Code"); Text("~/.claude/projects/").font(.caption).foregroundColor(.secondary) }
            Text("More tools coming soon.").font(.caption).foregroundColor(.secondary).padding(.top, 4)
        }
    }
}

// MARK: - Repos

/// Persistable repo search directories
private let repoDirsKey = "repo_search_dirs"

struct GitReposView: View {
    @State private var searchDirs: [String] = ["~/dev", "~/projects", "~/code"]
    @State private var repos: [String] = []
    @State private var refreshed = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Git Repositories").font(.headline)
            Text("Repos in these directories are monitored for commit changes.")
                .font(.caption).foregroundColor(.secondary)

            // Directory list
            List {
                ForEach(searchDirs, id: \.self) { dir in
                    HStack {
                        Text(dir).font(.caption)
                        Spacer()
                        Button("✕") { searchDirs.removeAll { $0 == dir }; save(); rescan() }
                            .buttonStyle(.plain).foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 80)

            HStack {
                Button("Add Directory…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.prompt = "Select"
                    if panel.runModal() == .OK, let url = panel.url {
                        let path = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                        if !searchDirs.contains(path) { searchDirs.append(path); save(); rescan() }
                    }
                }
            }

            Divider()

            if repos.isEmpty {
                Text("No repos found. Add code directories above.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("\(repos.count) repositories found").font(.caption).foregroundColor(.secondary)
                ScrollView {
                    ForEach(repos, id: \.self) { repo in
                        Text(URL(fileURLWithPath: repo).lastPathComponent)
                            .font(.caption)
                    }
                }
                .frame(height: 80)
            }
        }
        .onAppear {
            load()
            if !refreshed { rescan(); refreshed = true }
        }
    }

    private func load() {
        if let saved = UserDefaults.standard.stringArray(forKey: repoDirsKey), !saved.isEmpty {
            searchDirs = saved
        }
    }
    private func save() {
        UserDefaults.standard.set(searchDirs, forKey: repoDirsKey)
    }
    private func rescan() {
        let fm = FileManager.default
        var found: [String] = []
        for dir in searchDirs {
            let expanded = NSString(string: dir).expandingTildeInPath
            guard fm.fileExists(atPath: expanded) else { continue }
            guard let e = fm.enumerator(at: URL(fileURLWithPath: expanded),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for case let url as URL in e {
                let git = url.appendingPathComponent(".git")
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: git.path, isDirectory: &isDir), isDir.boolValue {
                    found.append(url.path)
                    e.skipDescendants()
                }
            }
        }
        repos = found.sorted()
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
        VStack(alignment: .leading) {
            Text("Subscription Tools").font(.headline)
            Text("Monthly fee tools. Cost per line = fee / net lines committed.")
                .font(.caption).foregroundColor(.secondary).padding(.bottom, 4)

            // Preset picker
            HStack {
                Picker("Add preset:", selection: $newName) {
                    Text("Choose…").tag("")
                    ForEach(presets, id: \.name) { p in
                        ForEach(p.tiers, id: \.label) { t in
                            Text("\(p.name) \(t.label) ($\(String(format: "%.0f", t.fee))/mo)").tag("\(p.name)|\(t.label)|\(t.fee)")
                        }
                    }
                }
                .frame(width: 280)
                Button("Add") {
                    let parts = newName.components(separatedBy: "|")
                    guard parts.count == 3, let fee = Double(parts[2]) else { return }
                    let tool = SubTool(name: "\(parts[0]) \(parts[1])", monthlyFee: fee, currency: "USD")
                    tools.append(tool); saveToDB(tool); newName = ""
                }
                .disabled(newName.isEmpty)
            }

            // Current subscriptions
            List {
                ForEach(tools) { tool in
                    HStack {
                        Text(tool.name)
                        Spacer()
                        Text("$\(String(format: "%.2f", tool.monthlyFee))/mo").foregroundColor(.secondary)
                    }
                }
                .onDelete { idx in
                    for i in idx { deleteFromDB(tools[i]); tools.remove(at: i) }
                }
            }
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
