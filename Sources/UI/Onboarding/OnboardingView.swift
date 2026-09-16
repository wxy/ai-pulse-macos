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
    @State private var selectedDevDir: String? = nil
    private let repoDirsKey = "repo_search_dirs"

    var body: some View {
        VStack(spacing: 0) {
            // Step indicator (v2 §4.7: 4 steps → 3 — tools auto-enable on
            // detection, keys/plans live in Settings → 增强)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }.padding(.top, 20).padding(.bottom, 8)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: authorizeStep
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
                if step < 2 {
                    Button(I18n.t("onboarding.next")) { step += 1 }
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

    // MARK: - Step 1: Authorize (home + dev dir)

    var authorizeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(I18n.t("onboarding.authorize_title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("onboarding.authorize_desc"))
                .font(.caption).foregroundColor(.secondary)

            // Home folder access (gates ~/.claude, ~/.codex, ~/.qwen detection)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: homeGranted ? "checkmark.circle.fill" : "folder.badge.person.crop")
                        .foregroundColor(homeGranted ? .green : .accentColor)
                    Text(I18n.t("onboarding.authorize_home_title")).font(.body).fontWeight(.medium)
                    Spacer()
                    if !homeGranted {
                        Button(I18n.t("bookmark.grant_to_detect")) { grantHomeAndRedetect() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Text(I18n.t("onboarding.grant_home_hint"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            // Development folder (repo scanning + aider detection)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundColor(.accentColor)
                    Text(I18n.t("onboarding.authorize_dev_title")).font(.body).fontWeight(.medium)
                    Spacer()
                    Button(I18n.t("bookmark.grant")) { selectDevDir() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Text(I18n.t("onboarding.authorize_dev_desc"))
                    .font(.caption2).foregroundColor(.secondary)
                if let dev = selectedDevDir {
                    Text(dev).font(.caption).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 24)
    }

    private var homeGranted: Bool {
        !BookmarkManager.isSandboxed || BookmarkManager.hasHomeAccess
    }

    /// Pick one dev directory, persist it to repo_search_dirs, kick a background
    /// fast scan, and re-detect so aider (dev-dir based) updates on the next page.
    private func selectDevDir() {
        guard let url = BookmarkManager.requestAccess(
            message: I18n.t("bookmark.repos_message"),
            defaultDirectory: BookmarkManager.homeDirPath
        ) else { return }
        let p = url.path
        selectedDevDir = p
        var dirs = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
        let expanded = NSString(string: p).expandingTildeInPath
        if !dirs.contains(expanded) { dirs.append(expanded) }
        UserDefaults.standard.set(dirs, forKey: repoDirsKey)
        Task { await RepoScanCache.shared.scan(dir: p) }
        runDetection()
    }

    // MARK: - Step 2: Done
    // v2 §4.7: the old devTools/apiProviders steps are gone — tools auto-enable
    // on detection (zero-config), and keys/plans live in Settings → 增强.

    var doneStep: some View {
        let totalRepos = RepoScanCache.shared.totalRepos(
            in: UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? [])
        let hasAnyConfig = !enabledIds.isEmpty || totalRepos > 0
        return VStack(spacing: 16) {
            Text("🎉").font(.system(size: 48))
            Text(I18n.t("onboarding.done_title")).font(.title2).fontWeight(.bold)
            Text(I18n.t("onboarding.done_msg"))
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if totalRepos > 0 {
                Text(String(format: I18n.t("onboarding.done_repos_count"), totalRepos))
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
            // v2 §4.7 盲区诚实化: direct-API usage leaves no local logs — say so
            // once, and point at the optional (collapsed) enhancement section.
            let hasApiKeyData = detectionResults.contains { r in
                r.1.found && IntegrationCategory.category(for: r.0) == .apiKeys
            }
            if !hasApiKeyData {
                Text(I18n.t("onboarding.blindspot_hint"))
                    .font(.caption).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
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
