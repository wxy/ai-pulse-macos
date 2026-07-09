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

    /// Parse the Claude status cache JSON. Internal for testing.
    static func parseClaudeStatusCache(_ json: [String: Any]) -> (utilization5h: Double, utilization7d: Double, limitStatus: String)? {
        guard let usageData = json["usageData"] as? [String: Any] else { return nil }
        let util5h = usageData["utilization5h"] as? Double ?? 0
        let util7d = usageData["utilization7d"] as? Double ?? 0
        let limitStatus = usageData["limitStatus"] as? String ?? ""
        return (util5h, util7d, limitStatus)
    }

    /// Read Claude rate-limit utilization from the VSCode status cache.
    /// Written by Claude Code's `/statusline` feature.
    func refreshClaudeStatus() {
        let home = FileManager.default.realHomeDirectory
        let cacheURL = home.appendingPathComponent(".claude/vscode-claude-status-cache.json")

        guard let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = Self.parseClaudeStatusCache(json)
        else {
            Logger.debug("UsageMonitor: Claude status cache not found or unreadable")
            return
        }

        let usagePercent = max(status.utilization5h, status.utilization7d) * 100

        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        UPDATE cost_source SET usage_percent = ?, usage_limit_status = ?
                        WHERE kind = 'subscription' AND id LIKE 'sub:claude-code:%'
                        """, arguments: [usagePercent, status.limitStatus])
                }
            } catch {
                Logger.debug("UsageMonitor: claude status update failed: \(error)")
            }
        }

        Logger.debug("UsageMonitor: Claude status 5h=\(String(format: "%.0f", status.utilization5h*100))% 7d=\(String(format: "%.0f", status.utilization7d*100))% limit=\(status.limitStatus)")
    }

    // MARK: - GitHub Copilot (HTTP)

    /// Parse the Copilot API response JSON. Internal for testing.
    static func parseCopilotResponse(_ json: [String: Any]) -> (usedPercent: Double, overageCount: Int)? {
        guard let snapshots = json["quota_snapshots"] as? [String: Any],
              let premium = snapshots["premium_interactions"] as? [String: Any],
              let percentRemaining = premium["percent_remaining"] as? Double
        else { return nil }
        let overageCount = (premium["overage_count"] as? Int) ?? Int(premium["overage_count"] as? Double ?? 0)
        let usedPercent = 100 - percentRemaining
        return (usedPercent, overageCount)
    }

    /// Poll the Copilot internal usage API for premium request quota.
    func refreshCopilotStatus() {
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
                AppHealthMonitor.shared.reportAPIError(providerId: "copilot-usage",
                    message: "Copilot usage: \(error.localizedDescription)")
                return
            }
            guard let data,
                  let httpResp = resp as? HTTPURLResponse,
                  httpResp.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let parsed = Self.parseCopilotResponse(json)
            else {
                Logger.debug("UsageMonitor: Copilot API unexpected response")
                AppHealthMonitor.shared.reportAPIError(providerId: "copilot-usage",
                    message: "Copilot usage: unexpected response")
                return
            }

            AppHealthMonitor.shared.clearAPIError(providerId: "copilot-usage")
            let usedPercent = parsed.usedPercent
            let overageCount = parsed.overageCount

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
                    DispatchQueue.main.async {
                        Logger.debug("UsageMonitor: copilot status update failed: \(error)")
                    }
                }
            }

            DispatchQueue.main.async {
                Logger.debug("UsageMonitor: Copilot used \(String(format: "%.0f", usedPercent))% overage=\(overageCount)")
            }
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
