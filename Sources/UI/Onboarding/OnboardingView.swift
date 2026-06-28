import SwiftUI

struct OnboardingView: View {
    @State private var step = 0
    @State private var detectionResults: [(any Detectable, DetectionResult)] = []
    @State private var enabledIds: Set<String> = []
    // New: repo selection
    @State private var searchDirs: [String] = ["~/dev", "~/projects", "~/code"]
    @State private var discoveredRepos: [String] = []     // full paths
    @State private var selectedRepos: Set<String> = []
    @State private var isScanning = false
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
                case 1: detectionStep
                case 2: reposStep     // NEW
                default: doneStep      // was step 2, now step 3
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation
            HStack {
                if step > 0 {
                    Button(I18n.t("onboarding.back")) { step -= 1 }
                }
                Spacer()
                if step < 3 {
                    if step == 2 {
                        // Repos step: allow skip
                        Button(I18n.t("onboarding.skip")) { step += 1 }
                            .padding(.trailing, 8)
                    }
                    Button(I18n.t("onboarding.next")) {
                        if step == 2 { saveRepos() }
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
            Text("🤖").font(.system(size: 56))
            Text("AI Pulse").font(.title).fontWeight(.bold)
            Text(I18n.t("onboarding.welcome"))
                .font(.title2).foregroundColor(.secondary)
            Text(I18n.t("onboarding.desc"))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Text(I18n.t("onboarding.privacy"))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    // MARK: - Step 1: Detection results

    var detectionStep: some View {
        let detected = detectionResults.filter(\.1.found)
        return VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("onboarding.detected")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("onboarding.detected_hint"))
                .font(.caption).foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(detected, id: \.0.id) { (integration, result) in
                        IntegrationRow(integration: integration, detected: result)
                    }
                    if detected.isEmpty {
                        Text(I18n.t("onboarding.no_tools"))
                            .foregroundColor(.secondary).padding()
                    }
                }
            }
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Step 2: Repo selection

    var reposStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(I18n.t("onboarding.repos_title")).font(.title3).fontWeight(.semibold)
            Text(I18n.t("onboarding.repos_hint"))
                .font(.caption).foregroundColor(.secondary)

            if isScanning {
                HStack {
                    ProgressView().scaleEffect(0.8)
                    Text(I18n.t("onboarding.repos_scanning")).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            } else if discoveredRepos.isEmpty {
                Text(I18n.t("repos.no_repos"))
                    .foregroundColor(.secondary).padding()
                Spacer()
            } else {
                Text(String(format: I18n.t("onboarding.repos_count"), discoveredRepos.count))
                    .font(.caption).foregroundColor(.secondary)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(discoveredRepos, id: \.self) { repo in
                            let name = URL(fileURLWithPath: repo).lastPathComponent
                            HStack {
                                Toggle(isOn: Binding(
                                    get: { selectedRepos.contains(repo) },
                                    set: { v in
                                        if v { selectedRepos.insert(repo) }
                                        else { selectedRepos.remove(repo) }
                                    }
                                )) {}.toggleStyle(.checkbox)
                                Image(systemName: "chevron.left.forwardslash.chevron.right")
                                    .foregroundColor(.secondary)
                                Text(name).font(.body)
                                Spacer()
                                Text(repo.replacingOccurrences(
                                    of: FileManager.default.homeDirectoryForCurrentUser.path,
                                    with: "~"))
                                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .onAppear { scanRepos() }
    }

    // MARK: - Step 3: Done

    var doneStep: some View {
        VStack(spacing: 16) {
            Text("🎉").font(.system(size: 48))
            Text(I18n.t("onboarding.done_title")).font(.title2).fontWeight(.bold)
            Text(I18n.t("onboarding.done_msg"))
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if !selectedRepos.isEmpty {
                Text(String(format: I18n.t("onboarding.done_repos_count"), selectedRepos.count))
                    .font(.caption).foregroundColor(.secondary)
            }
            if detectionResults.contains(where: { $0.1.found && $0.0.grade == .A }) {
                Text(I18n.t("onboarding.done_cpl"))
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Helpers

    func gradeBadge(_ g: DataGrade) -> some View {
        Text("[\(g.rawValue)] \(gradeLabel(g))")
            .font(.caption2).foregroundColor(.secondary)
    }

    func gradeLabel(_ g: DataGrade) -> String {
        switch g {
        case .A: return "CPL"
        case .B: return "Balance"
        case .C: return "Sub"
        }
    }

    func runDetection() {
        detectionResults = IntegrationRegistry.all.map { ($0, $0.detect()) }
        // Auto-enable detected A-grade integrations (zero-config, just consent)
        for (i, r) in detectionResults where r.found && i.grade == .A {
            enabledIds.insert(i.id)
        }
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

    func scanRepos() {
        isScanning = true
        Task {
            let fm = FileManager.default
            var allRepos = Set<String>()
            for dir in searchDirs {
                let expanded = NSString(string: dir).expandingTildeInPath
                guard fm.fileExists(atPath: expanded),
                      let e = fm.enumerator(at: URL(fileURLWithPath: expanded),
                                            includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                else { continue }
                for case let url as URL in e {
                    let git = url.appendingPathComponent(".git")
                    var d: ObjCBool = false
                    if fm.fileExists(atPath: git.path, isDirectory: &d), d.boolValue {
                        allRepos.insert(url.path)
                        e.skipDescendants()
                    }
                }
            }
            await MainActor.run {
                discoveredRepos = allRepos.sorted()
                isScanning = false
            }
        }
    }

    func saveRepos() {
        // Save selected repos' parent directories to UserDefaults
        if !selectedRepos.isEmpty {
            var dirs = Set<String>()
            for repoPath in selectedRepos {
                let parent = URL(fileURLWithPath: repoPath).deletingLastPathComponent().path
                let short = parent.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                dirs.insert(short)
            }
            // Merge with existing dirs
            var existing = UserDefaults.standard.stringArray(forKey: repoDirsKey) ?? []
            for d in dirs where !existing.contains(d) {
                existing.append(d)
            }
            UserDefaults.standard.set(existing, forKey: repoDirsKey)
        }
    }

    func close() {
        finish()
        OnboardingWindowManager.shared.window?.close()
    }
}

// MARK: - Window Manager

final class OnboardingWindowManager {
    static let shared = OnboardingWindowManager()
    var window: NSWindow?
}
