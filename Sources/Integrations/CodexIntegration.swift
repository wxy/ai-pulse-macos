import Foundation
import AppKit

/// ChatGPT (formerly Codex) — log-based integration.
/// Covers both the ChatGPT desktop app and the Codex CLI: the desktop app
/// (bundle id `com.openai.codex`) writes its sessions into the same
/// `~/.codex/sessions/**/rollout-*.jsonl` directory as the CLI.
/// Data source: `~/.codex/sessions/**/rollout-*.jsonl`
/// Not a CostSource itself — log entries are attributed to the existing
/// `openai` apiKey CostSource via the Arbitrator.
struct CodexIntegration: Detectable {
    let id = "codex"
    let displayName = "ChatGPT"
    var costSources: [CostSource] { [] }

    func detect() -> DetectionResult {
        let home = FileManager.default.realHomeDirectory
        let sessionsDir = home.appendingPathComponent(".codex/sessions")
        // Require at least one session dir (year/) to count as "found".
        let hasSessions = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir.path))?
            .contains { Int($0) != nil } ?? false
        let sessionCount = sessionCount(in: sessionsDir)

        // The ChatGPT desktop app writes a `state_5.sqlite` / `logs_2.sqlite`
        // next to the CLI sessions — presence of either means the app (or a
        // recent Codex install) has been used on this machine.
        let desktopDb = home.appendingPathComponent(".codex/state_5.sqlite")
        let hasDesktopData = FileManager.default.fileExists(atPath: desktopDb.path)
        let appInstalled = Self.chatgptAppInstalled()

        let found = hasSessions || hasDesktopData
        return DetectionResult(
            found: found,
            summary: found
                ? appInstalled && hasSessions
                    ? String(format: I18n.t("detect.chatgpt_desktop_found"), sessionCount)
                    : I18n.t("detect.codex_found")
                : I18n.t("detect.codex_not_found")
        )
    }

    /// Number of per-day session directories under `~/.codex/sessions/YYYY/MM/DD`.
    private func sessionCount(in sessionsDir: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
        where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
            count += 1
        }
        return count
    }

    /// True if the ChatGPT desktop app (bundle id `com.openai.codex`, the
    /// renamed Codex app) is installed. Uses LaunchServices so it works inside
    /// the App Sandbox without file access to /Applications.
    private static func chatgptAppInstalled() -> Bool {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") != nil {
            return true
        }
        // Fallback for sandboxed LaunchServices misses: the app bundle path.
        return FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app")
    }
}
