import Foundation

/// A-grade: Claude Code log parsing.
/// Data source: `~/.claude/projects/<encoded-cwd>/*.jsonl`
struct ClaudeCodeIntegration: Detectable, Collectable {
    let id = "claude-code"
    let displayName = "Claude Code"
    let grade: DataGrade = .A

    func detect() -> DetectionResult {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        let exists = FileManager.default.fileExists(atPath: dir.path)
        let sessions = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.count ?? 0
        return DetectionResult(
            found: exists && sessions > 0,
            summary: exists
                ? String(format: I18n.t("detect.claude_found"), sessions)
                : I18n.t("detect.claude_not_found")
        )
    }

    func start() { LogWatcher.shared.start() }
    func stop()  { LogWatcher.shared.stop() }
}
