import Foundation
import GRDB

/// Monitors subscription IDE usage percentages:
/// - Claude Pro/Max: reads `~/.claude/vscode-claude-status-cache.json` (local, zero network)
/// - GitHub Copilot: polls `GET api.github.com/copilot_internal/user` (HTTP OAuth)
nonisolated final class UsageMonitor: @unchecked Sendable {
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
    /// `reset5hAt`/`reset7dAt` are Unix timestamps (seconds) of the next
    /// 5-hour / 7-day quota reset.
    static func parseClaudeStatusCache(_ json: [String: Any]) -> (utilization5h: Double?, utilization7d: Double?, limitStatus: String, reset5hAt: Double, reset7dAt: Double)? {
        guard let usageData = json["usageData"] as? [String: Any] else { return nil }
        let util5h = (usageData["utilization5h"] as? NSNumber)?.doubleValue
        let util7d = (usageData["utilization7d"] as? NSNumber)?.doubleValue
        guard util5h != nil || util7d != nil else { return nil }
        let limitStatus = usageData["limitStatus"] as? String ?? ""
        // Timestamps may arrive as Int or Double in JSON → use NSNumber to accept both.
        let reset5hAt = (usageData["reset5hAt"] as? NSNumber)?.doubleValue ?? 0
        let reset7dAt = (usageData["reset7dAt"] as? NSNumber)?.doubleValue ?? 0
        return (util5h, util7d, limitStatus, reset5hAt, reset7dAt)
    }

    /// The payload's source time wins over file copying/touching. Missing or
    /// invalid source time cannot establish a current quota observation.
    static func claudeObservationDate(_ json: [String: Any], modifiedAt: Date, now: Date = Date()) -> Date? {
        guard let timestamp = json["updatedAt"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let source = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        guard let source, source <= now, modifiedAt <= now else { return nil }
        return min(source, modifiedAt)
    }

    static func latestClaudeModel(in db: Database, now: Date) throws -> String? {
        let end = Int64(now.timeIntervalSince1970 * 1_000)
        return try String.fetchOne(db, sql: """
            SELECT model FROM usage_event
            WHERE source = 'claude-code' AND model IS NOT NULL AND model != '<synthetic>'
              AND ts >= ? AND ts <= ?
            ORDER BY ts DESC, id DESC LIMIT 1
            """, arguments: [end - 5 * 3_600_000, end])
    }

    /// Read Claude rate-limit utilization from the VSCode status cache.
    /// Written by Claude Code's `/statusline` feature.
    func refreshClaudeStatus() {
        let home = FileManager.default.realHomeDirectory
        let cacheURL = home.appendingPathComponent(".claude/vscode-claude-status-cache.json")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date,
              let data = try? Data(contentsOf: cacheURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = Self.parseClaudeStatusCache(json),
              let sourceDate = Self.claudeObservationDate(json, modifiedAt: modifiedAt)
        else {
            Logger.debug("UsageMonitor: Claude status cache not found or unreadable")
            return
        }

        Task {
            // Only meaningful when Claude Code actually consumes an Anthropic
            // subscription. If routed through a third-party API (DeepSeek /
            // BYOK), the status cache reflects a stale Anthropic quota that
            // does not apply — skip it.
            guard await isClaudeCodeUsingAnthropicModel() else {
                Logger.debug("UsageMonitor: Claude Code using third-party models — skipping Anthropic quota")
                return
            }
            do {
                try await AppDatabase.shared.write { db in
                    // Reading an unchanged cache must not renew its validity.
                    let observedAt = sourceDate.timeIntervalSince1970
                    if let utilization = status.utilization5h {
                        try Self.upsertQuotaWindow(
                            in: db, toolId: "claude-code", windowId: "5h",
                            utilization: utilization * 100, limitStatus: status.limitStatus,
                            resetAt: status.reset5hAt, windowSeconds: 5 * 3_600,
                            updatedAt: observedAt)
                    }
                    if let utilization = status.utilization7d {
                        try Self.upsertQuotaWindow(
                            in: db, toolId: "claude-code", windowId: "7d",
                            utilization: utilization * 100, limitStatus: status.limitStatus,
                            resetAt: status.reset7dAt, windowSeconds: 7 * 86_400,
                            updatedAt: observedAt)
                    }
                }
            } catch {
                Logger.debug("UsageMonitor: claude status update failed: \(error)")
            }
        }

        Logger.debug("UsageMonitor: Claude status 5h=\(status.utilization5h.map { String(format: "%.0f", $0 * 100) } ?? "--")% 7d=\(status.utilization7d.map { String(format: "%.0f", $0 * 100) } ?? "--")% limit=\(status.limitStatus)")
    }

    /// Recent model family is an eligibility filter, not proof of payment.
    private func isClaudeCodeUsingAnthropicModel() async -> Bool {
        do {
            let now = Date()
            let model = try await AppDatabase.shared.read { db in
                try Self.latestClaudeModel(in: db, now: now)
            }
            guard let model else { return false }
            return ModelCatalogManager.normalize(model).hasPrefix("claude-")
        } catch {
            Logger.debug("UsageMonitor: model check failed: \(error)")
            return false
        }
    }

    // MARK: - GitHub Copilot (HTTP)

    /// Parse the Copilot API response JSON. Internal for testing.
    /// `quotaResetDate` is the ISO-8601 timestamp of the next quota reset
    /// (top-level `quota_reset_date`), converted to a Unix timestamp in seconds.
    static nonisolated func parseCopilotResponse(_ json: [String: Any]) -> (usedPercent: Double, overageCount: Int, quotaResetAt: Double)? {
        guard let snapshots = json["quota_snapshots"] as? [String: Any],
              let premium = snapshots["premium_interactions"] as? [String: Any],
              let percentRemaining = premium["percent_remaining"] as? Double
        else { return nil }
        let overageCount = (premium["overage_count"] as? Int) ?? Int(premium["overage_count"] as? Double ?? 0)
        // Clamp: some proxies report percent_remaining outside 0-100.
        let usedPercent = min(max(100 - percentRemaining, 0), 100)

        var resetAt: Double = 0
        if let iso = json["quota_reset_date"] as? String,
           let date = ISO8601DateFormatter().date(from: iso) {
            resetAt = date.timeIntervalSince1970
        }
        return (usedPercent, overageCount, resetAt)
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

        session.dataTask(with: req) { [healthMonitor = AppHealthMonitor.shared] data, resp, error in
            if let error {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                                        Logger.debug("UsageMonitor: Copilot API error: \(error.localizedDescription)")
                                        healthMonitor.reportAPIError(providerId: "copilot-usage",
                                            message: "Copilot usage: \(error.localizedDescription)")
                    }
                }
                return
            }
            guard let data,
                  let httpResp = resp as? HTTPURLResponse,
                  httpResp.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                                        Logger.debug("UsageMonitor: Copilot API unexpected response")
                                        healthMonitor.reportAPIError(providerId: "copilot-usage",
                                            message: "Copilot usage: unexpected response")
                    }
                }
                return
            }

            guard let parsed = Self.parseCopilotResponse(json) else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                                        Logger.debug("UsageMonitor: Copilot API unexpected response")
                                        healthMonitor.reportAPIError(providerId: "copilot-usage",
                                            message: "Copilot usage: unexpected response")
                    }
                }
                return
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                                healthMonitor.clearAPIError(providerId: "copilot-usage")
                }
            }
            let usedPercent = parsed.usedPercent
            let overageCount = parsed.overageCount
            let quotaResetAt = parsed.quotaResetAt

            Task {
                do {
                    try await AppDatabase.shared.write { db in
                        let limitStatus = overageCount > 0 ? "overage" : "normal"
                        try Self.upsertQuotaWindow(
                            in: db, toolId: "copilot", windowId: "monthly",
                            utilization: usedPercent, limitStatus: limitStatus,
                            resetAt: quotaResetAt, windowSeconds: 30 * 86_400,
                            updatedAt: Date().timeIntervalSince1970)
                    }
                } catch {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Logger.debug("UsageMonitor: copilot status update failed: \(error)")
                        }
                    }
                }
            }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Logger.debug("UsageMonitor: Copilot used \(String(format: "%.0f", usedPercent))% overage=\(overageCount)")
                }
            }
        }.resume()
    }

    static func upsertQuotaWindow(
        in db: Database,
        toolId: String,
        windowId: String,
        utilization: Double,
        limitStatus: String,
        resetAt: Double,
        windowSeconds: Double,
        updatedAt: Double
    ) throws {
        guard utilization.isFinite, resetAt.isFinite, windowSeconds.isFinite,
              windowSeconds > 0, updatedAt.isFinite, updatedAt > 0 else { return }
        let safeUtilization = min(max(utilization, 0), 100)
        try db.execute(sql: """
            INSERT INTO quota_window_status
              (tool_id, window_id, utilization, limit_status, reset_at,
               window_seconds, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(tool_id, window_id) DO UPDATE SET
                utilization = excluded.utilization,
                limit_status = excluded.limit_status,
                reset_at = excluded.reset_at,
                window_seconds = excluded.window_seconds,
                updated_at = excluded.updated_at
            """, arguments: [toolId, windowId, safeUtilization, limitStatus,
                             resetAt > 0 ? resetAt : nil, windowSeconds, updatedAt])
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
