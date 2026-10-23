import SwiftUI

/// Used by setup, repository settings and the dashboard; never opens a panel
/// automatically. A cancelled or unrelated selection leaves the issue visible.
struct DirectoryAccessGuidance: View {
    var logicalPrefix: String? = nil
    var onGranted: (() -> Void)? = nil
    @State private var issues: [DirectoryAccessIssue] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    Label(issue.message, systemImage: "folder.badge.questionmark")
                        .font(.caption).foregroundStyle(.orange)
                    if issue.logicalPath != issue.targetPath {
                        Text(verbatim: issue.logicalPath + " → " + issue.targetPath)
                            .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if issue.kind == .permission {
                        Button(I18n.t("access.authorize")) {
                            guard BookmarkManager.requestAccess(for: issue) else { return }
                            if let onGranted { onGranted() }
                            else { Self.resumeReading() }
                        }.accessibilityIdentifier("authorize-real-folder")
                    } else {
                        Text(verbatim: issue.detail).font(.caption2).foregroundStyle(.secondary)
                        Button(I18n.t("access.retry")) {
                            if let onGranted { onGranted() }
                            else { Self.resumeReading() }
                        }
                    }
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: DirectoryAccess.didChange)) { _ in refresh() }
    }

    private func refresh() {
        issues = logicalPrefix.map { DirectoryAccess.shared.issues(under: $0) } ?? DirectoryAccess.shared.issues
    }

    @MainActor
    static func resumeReading() {
        // Stored roots remain logical aliases. Resolve their current targets on
        // each scan; granting a destination does not reconfigure those roots.
        for root in UserDefaults.standard.stringArray(forKey: "repo_search_dirs") ?? [] {
            RepoScanCache.shared.invalidate(dir: root)
            Task { await RepoScanCache.shared.scan(dir: root) }
        }
        LogWatcher.shared.start()
        DataRefreshCoordinator.shared.triggerIngest()
    }
}
