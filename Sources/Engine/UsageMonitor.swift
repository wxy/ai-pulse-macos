import Foundation
import GRDB

/// Monitors subscription IDE usage percentages:
/// - Claude Pro/Max: reads `~/.claude/vscode-claude-status-cache.json` (local, zero network)
/// - GitHub Copilot: polls `GET api.github.com/copilot_internal/user` (HTTP OAuth)
final class UsageMonitor: @unchecked Sendable {
    static let shared = UsageMonitor()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - Claude Pro/Max (local cache)

    /// Read Claude rate-limit utilization from the VSCode status cache.
    /// Written by Claude Code's `/statusline` feature.
    func refreshClaudeStatus() {
        let home = FileManager.default.realHomeDirectory
        let cacheURL = home.appendingPathComponent(".claude/vscode-claude-status-cache.json")

        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usageData = json["usageData"] as? [String: Any]
        else {
            Logger.debug("UsageMonitor: Claude status cache not found or unreadable")
            return
        }

        let util5h: Double = usageData["utilization5h"] as? Double ?? 0
        let util7d: Double = usageData["utilization7d"] as? Double ?? 0
        let limitStatus: String = usageData["limitStatus"] as? String ?? ""

        // Use the higher of 5h/7d utilization for the percentage display
        let usagePercent = max(util5h, util7d) * 100

        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        UPDATE cost_source SET usage_percent = ?, usage_limit_status = ?
                        WHERE kind = 'subscription' AND id LIKE 'sub:claude-code:%'
                        """, arguments: [usagePercent, limitStatus])
                }
            } catch {
                Logger.debug("UsageMonitor: claude status update failed: \(error)")
            }
        }

        Logger.debug("UsageMonitor: Claude status 5h=\(String(format: "%.0f", util5h*100))% 7d=\(String(format: "%.0f", util7d*100))% limit=\(limitStatus)")
    }

    // MARK: - GitHub Copilot (HTTP)

    /// Poll the Copilot internal usage API for premium request quota.
    func refreshCopilotStatus() {
        // Uses the Copilot OAuth token from VS Code's auth cache
        guard let token = copilotToken() else {
            Logger.debug("UsageMonitor: no Copilot token found")
            return
        }

        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10

        session.dataTask(with: req) { data, resp, error in
            if let error {
                Logger.debug("UsageMonitor: Copilot API error: \(error.localizedDescription)")
                return
            }
            guard let data,
                  let httpResp = resp as? HTTPURLResponse,
                  httpResp.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let snapshots = json["quota_snapshots"] as? [String: Any],
                  let premium = snapshots["premium_interactions"] as? [String: Any],
                  let percentRemaining = premium["percent_remaining"] as? Double
            else {
                Logger.debug("UsageMonitor: Copilot API unexpected response")
                return
            }

            let overageCount = premium["overage_count"] as? Int ?? 0
            let usedPercent = 100 - percentRemaining

            Task {
                do {
                    try await AppDatabase.shared.write { db in
                        let limitStatus = overageCount > 0 ? "overage" : "normal"
                        try db.execute(sql: """
                            UPDATE cost_source SET usage_percent = ?, usage_limit_status = ?
                            WHERE kind = 'subscription' AND id LIKE 'sub:copilot:%'
                            """, arguments: [usedPercent, limitStatus])
                    }
                } catch {
                    Logger.debug("UsageMonitor: copilot status update failed: \(error)")
                }
            }

            Logger.debug("UsageMonitor: Copilot used \(String(format: "%.0f", usedPercent))% remaining=\(String(format: "%.0f", percentRemaining))% overage=\(overageCount)")
        }.resume()
    }

    // MARK: - Token extraction

    /// Extract Copilot OAuth token from VS Code's auth cache.
    private func copilotToken() -> String? {
        let home = FileManager.default.realHomeDirectory
        let paths = [
            "Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilot-auth.json",
            "Library/Application Support/Code - Insiders/User/globalStorage/github.copilot-chat/copilot-auth.json",
        ]
        for p in paths {
            let url = home.appendingPathComponent(p)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["accessToken"] as? String ?? json["token"] as? String
            else { continue }
            return token
        }
        return nil
    }
}
