import SwiftUI

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
    @State private var detectionResults: [(any Detectable, DetectionResult)] = []
    @State private var enabledIds: Set<String> = []
    @State private var dirEntries: [DirEntry] = []
    private let repoDirsKey = "repo_search_dirs"

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }.padding(.top, 20).padding(.bottom, 8)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: apiProvidersStep
                case 2: devToolsStep
                case 3: reposStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack {
                if step == 0 {
                    Button(I18n.t("demo.skip_welcome")) {
                        DemoData.isManual = true
                        close()
                    }
                } else if step > 0 {
                    Button(I18n.t("onboarding.back")) { step -= 1 }
                }
                Spacer()
                if step < 4 {
                    if step == 3 {
                        // Repos step: allow skip
                        Button(I18n.t("onboarding.skip")) { step += 1 }
                            .padding(.trailing, 8)
                    }
                    Button(I18n.t("onboarding.next")) {
                        if step == 3 { saveRepos() }
                        step += 1
                    }
                } else {
                    Button(I18n.t("onboarding.close")) { close() }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
        .frame(width: 520, height: 480)  // was 440, slightly taller for repo list
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { runDetection() }
    }

    // MARK: - Step 0: Welcome

    var welcomeStep: some View {
        VStack(spacing: 16) {
            Image(nsImage: AppIconLoader.uiImage(size: 72))
            Text(I18n.t("app.name")).font(.title).fontWeight(.bold)
            Text(I18n.t("onboarding.welcome"))
                .font(.title2).foregroundColor(.secondary)
            Text(I18n.t("onboarding.desc"))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Text(I18n.t("onboarding.privacy"))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Step 1: Detection results

    /// Step 1: AI providers — every supported apiKey integration, whether or
    /// not a key is set yet (so the user can configure them here).
    var apiProvidersStep: some View {
        let items = detectionResults.filter {
            IntegrationCategory.category(for: $0.0) == .apiKeys
        }
        return detectionList(title: I18n.t("settings.integrations_api"),
                             hint: I18n.t("integrations.group_api_key_desc"),
                             items: items)
    }

    /// Step 2: Dev tools — every supported tool (log/subscription). Includes
    /// the sandbox home-directory grant since it gates log-based detection.
    var devToolsStep: some View {
        let items = detectionResults.filter {
            IntegrationCategory.category(for: $0.0) == .devTools
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("settings.integrations_devtools")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("integrations.group_editors_desc"))
                .font(.caption).foregroundColor(.secondary)

            if BookmarkManager.isSandboxed && !BookmarkManager.hasHomeAccess {
                HStack(spacing: 8) {
                    Image(systemName: "lock.open")
                    Text(I18n.t("onboarding.grant_home_hint"))
                        .font(.caption)
                    Spacer()
                    Button(I18n.t("bookmark.grant_to_detect")) { grantHomeAndRedetect() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(items, id: \.0.id) { (integration, result) in
                        IntegrationRow(integration: integration, detected: result)
                    }
                    if items.isEmpty {
                        Text(I18n.t("onboarding.no_tools"))
                            .foregroundColor(.secondary).padding()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    private func detectionList(title: String, hint: String,
                               items: [(any Detectable, DetectionResult)]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3).fontWeight(.semibold)
            Text(hint).font(.caption).foregroundColor(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(items, id: \.0.id) { (integration, result) in
                        IntegrationRow(integration: integration, detected: result)
                    }
                    if items.isEmpty {
                        Text(I18n.t("onboarding.no_tools"))
                            .foregroundColor(.secondary).padding()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 2: Repo directories

    var reposStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(I18n.t("onboarding.repos_title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("onboarding.repos_hint"))
                .font(.caption).foregroundColor(.secondary)

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
                                Toggle(isOn: $entry.isChecked) {}.toggleStyle(.checkbox)
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
                                        }.padding(.leading, 44)
                                    } else if entry.repos.isEmpty {
                                        Text(I18n.t("repos.no_repos"))
                                            .font(.caption2).foregroundColor(.secondary)
                                            .padding(.leading, 44)
                                    } else {
                                        ForEach(entry.repos, id: \.self) { name in
                                            HStack(spacing: 4) {
                                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                                    .font(.caption2).foregroundColor(.secondary)
                                                Text(name).font(.caption).lineLimit(1)
                                                Spacer()
                                            }
                                            .padding(.vertical, 2).padding(.leading, 44)
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
                    Label(I18n.t("repos.add"), systemImage: "plus.circle")
                        .font(.body).padding(.vertical, 4).padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .onAppear { startScan() }
    }

    // MARK: - Step 3: Done

    var doneStep: some View {
        let totalCheckedRepos = dirEntries.filter(\.isChecked).reduce(0) { $0 + $1.repoCount }
        let hasAnyConfig = !enabledIds.isEmpty || totalCheckedRepos > 0
        return VStack(spacing: 16) {
            Text("🎉").font(.system(size: 48))
            Text(I18n.t("onboarding.done_title")).font(.title2).fontWeight(.bold)
            Text(I18n.t("onboarding.done_msg"))
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if totalCheckedRepos > 0 {
                Text(String(format: I18n.t("onboarding.done_repos_count"), totalCheckedRepos))
                    .font(.caption).foregroundColor(.secondary)
            }
            // Show CPL hint if any log-parsing integration is detected
            let hasLogSource = detectionResults.contains { r in
                r.1.found && r.0.costSources.isEmpty && r.0 is any Collectable
            }
            if hasLogSource {
                Text(I18n.t("onboarding.done_cpl"))
                    .font(.caption).foregroundColor(.secondary)
            }
            // Demo mode notice — shown when nothing was configured
            if !hasAnyConfig {
                VStack(spacing: 6) {
                    Text(I18n.t("demo.onboarding_title"))
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    Text(I18n.t("demo.onboarding_msg"))
                        .font(.caption2).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .background(Color(nsColor: .quaternarySystemFill).opacity(0.5))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Helpers

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = I18n.t("bookmark.grant")
        panel.message = I18n.t("bookmark.repos_message")
        panel.directoryURL = FileManager.default.realHomeDirectory
        if panel.runModal() == .OK, let url = panel.url {
            // Persist a security-scoped bookmark so access survives relaunch (sandbox).
            BookmarkManager.createAndSave(for: url)
            // Store the absolute path: NSString.expandingTildeInPath resolves "~" against
            // the sandbox container, so a tilde path would break scanning under sandbox.
            let p = url.path
            guard !dirEntries.contains(where: { $0.path == p }) else { return }
            let entry = DirEntry(path: p)
            dirEntries.append(entry)
            // Save immediately
            saveRepos()
            // Kick off scan for just this dir
            let idx = dirEntries.count - 1
            Task { await scanOne(at: idx) }
        }
    }

    func runDetection() {
        detectionResults = IntegrationRegistry.visible.map { ($0, $0.detect()) }
        // Auto-enable log-based integrations that are detected
        for (i, r) in detectionResults where r.found && i.costSources.isEmpty && i is any Collectable {
            enabledIds.insert(i.id)
        }
    }

    /// Grant home-folder access (sandbox) then re-detect all tools.
    private func grantHomeAndRedetect() {
        guard BookmarkManager.requestHomeAccess(message: I18n.t("bookmark.home_message")) != nil
        else { return }
        runDetection()
    }

    func finish() {
        for id in enabledIds {
            var cfg = IntegrationRegistry.config(for: id)
            cfg.enabled = true
            IntegrationRegistry.setConfig(for: id, cfg)
        }
        IntegrationRegistry.startAllEnabled()
        UserDefaults.standard.set(true, forKey: "onboarding_completed")
    }

    // MARK: - Repo scanning

    func startScan() {
        // Load dirs from settings, fall back to defaults
        var dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        // Under sandbox, unauthorized guessed defaults (~/dev …) can't be read and would
        // only show "0 repos", confusing the user. Show an empty state + Add button instead.
        if dirs.isEmpty && !BookmarkManager.isSandboxed { dirs = ["~/dev", "~/projects", "~/code"] }
        dirEntries = dirs.map { DirEntry(path: $0) }
        Task {
            for i in dirEntries.indices {
                await scanOne(at: i)
            }
        }
    }

    /// Scan a single directory entry asynchronously.
    func scanOne(at idx: Int) async {
        guard idx < dirEntries.count else { return }
        let path = dirEntries[idx].path
        await MainActor.run { dirEntries[idx].isScanning = true }
        let foundRepos = await Task.detached { () -> [String] in
            let expanded = NSString(string: path).expandingTildeInPath
            let fm = FileManager.default
            var result: [String] = []
            let skippedDirs: Set<String> = ["Music", "Pictures", "Movies", "Library", ".Trash"]
            if fm.fileExists(atPath: expanded),
               let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: expanded),
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
               ) {
                while let url = enumerator.nextObject() as? URL {
                    if skippedDirs.contains(url.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
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
            if !foundRepos.isEmpty { dirEntries[idx].isChecked = true }
            dirEntries[idx].isScanning = false
        }
    }

    func saveRepos() {
        let checked = dirEntries.filter(\.isChecked).map(\.path)
        var existing = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        // Merge: add new checked, remove unchecked
        for d in checked where !existing.contains(d) { existing.append(d) }
        let unchecked = Set(dirEntries.filter { !$0.isChecked }.map(\.path))
        existing.removeAll { unchecked.contains($0) }
        UserDefaults.standard.set(existing, forKey: repoDirsKey)
    }

    func close() {
        finish()
        // Re-discover repos/logs so directories just authorized during onboarding
        // start being monitored without requiring an app relaunch.
        LogWatcher.shared.start()
        NotificationCenter.default.post(name: .dataDidChange, object: nil)
        NotificationCenter.default.post(name: .demoModeDidChange, object: nil)
        OnboardingWindowManager.shared.window?.close()
        // Auto-open Dashboard so the user sees the app after onboarding,
        // even if they skipped every step.
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
