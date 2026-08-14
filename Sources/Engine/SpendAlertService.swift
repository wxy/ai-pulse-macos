import Foundation
import GRDB
import UserNotifications

enum SpendAlertKind: String, Sendable {
    case spendRate = "spend_rate"
    case balanceDrop = "balance_drop"
}

struct SpendAlertPayload: Codable, Sendable {
    var eventId: String
    var level: Int
    var kind: String
    var source: String
    var amountUsd: Double
    var baselineUsd: Double?
    var occurredAt: Date
}

struct SpendAlertSettings {
    static let masterKey = "spend_alerts_enabled"
    var master: Bool

    static func current() -> SpendAlertSettings {
        let d = UserDefaults.standard
        return SpendAlertSettings(
            master: d.object(forKey: masterKey) == nil ? true : d.bool(forKey: masterKey)
        )
    }
}

/// Detects spend-rate spikes and balance drops, dedupes/cooldowns alerts,
/// then pushes the alert to CloudKit and posts a local macOS notification.
final class SpendAlertService: @unchecked Sendable {
    static let shared = SpendAlertService()

    private let thresholds = SpendAlertThresholds.standard
    private let lastFiredKey = "spend_alert_last_fired"

    private init() {}

    func check() async {
        let settings = SpendAlertSettings.current()
        guard settings.master else { return }

        var candidates: [SpendAlertPayload] = []
        candidates += await spendRateCandidates()
        candidates += await balanceDropCandidates()

        for payload in candidates {
            guard shouldFire(payload) else { continue }
            markFired(payload)
            await deliver(payload)
        }
    }

    // MARK: - Spend-rate spike

    private func spendRateCandidates() async -> [SpendAlertPayload] {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let hourMs = Int64(3_600_000)
        let dayMs = Int64(86_400_000)

        do {
            // 1-hour window vs 7-day hourly median.
            let hourlyBaseline = try await hourlyBaseline(nowMs: nowMs)
            let latestHour = try await cost(since: nowMs - hourMs)
            let hourLevel = SpendAlertRules.levelForSpendRate(
                current: latestHour, baseline: hourlyBaseline, thresholds: thresholds)

            // 24-hour window vs 7-day daily median.
            let dailyBaseline = try await dailyBaseline(nowMs: nowMs)
            let latestDay = try await cost(since: nowMs - dayMs)
            let dayLevel = SpendAlertRules.levelForSpendRate(
                current: latestDay, baseline: dailyBaseline, thresholds: thresholds)

            let level = [hourLevel, dayLevel].compactMap { $0 }.max()
            guard let level else { return [] }

            let baseline = max(hourlyBaseline, dailyBaseline)
            return [SpendAlertPayload(
                eventId: UUID().uuidString,
                level: level.rawValue,
                kind: SpendAlertKind.spendRate.rawValue,
                source: "aggregate",
                amountUsd: max(latestHour, latestDay),
                baselineUsd: baseline,
                occurredAt: now
            )]
        } catch {
            Logger.error("SpendAlertService: rate check failed: \(error)")
            return []
        }
    }

    private func hourlyBaseline(nowMs: Int64) async throws -> Double {
        let hourMs = Int64(3_600_000)
        let start = nowMs - 7 * 24 * hourMs
        let end = nowMs - hourMs  // exclude the in-progress hour from baseline
        let buckets = try await AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT (ts / ?) AS bucket, COALESCE(SUM(cost_usd), 0) AS c
                FROM usage_event
                WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                GROUP BY bucket
                """, arguments: [hourMs, start, end])
            return rows.map { ($0["c"] as Double? ?? 0) }
        }
        return SpendAlertRules.median(buckets)
    }

    private func dailyBaseline(nowMs: Int64) async throws -> Double {
        let dayMs = Int64(86_400_000)
        let start = nowMs - 7 * dayMs
        let end = nowMs - dayMs
        let buckets = try await AppDatabase.shared.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT (ts / ?) AS bucket, COALESCE(SUM(cost_usd), 0) AS c
                FROM usage_event
                WHERE ts >= ? AND ts < ? AND (model IS NULL OR model != '<synthetic>')
                GROUP BY bucket
                """, arguments: [dayMs, start, end])
            return rows.map { ($0["c"] as Double? ?? 0) }
        }
        return SpendAlertRules.median(buckets)
    }

    private func cost(since startMs: Int64) async throws -> Double {
        try await AppDatabase.shared.read { db in
            let value = try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(cost_usd), 0)
                FROM usage_event
                WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                """, arguments: [startMs]) ?? 0
            return value
        }
    }

    // MARK: - Balance drop

    private func balanceDropCandidates() async -> [SpendAlertPayload] {
        let now = Date()
        let dayMs = Int64(86_400_000)
        let startMs = Int64(now.timeIntervalSince1970 * 1000) - dayMs

        do {
            let rows = try await AppDatabase.shared.read { db -> [(providerId: String, ts: Int64, balance: Double, currency: String)] in
                let fetched = try Row.fetchAll(db, sql: """
                    SELECT provider_id, ts, balance, currency
                    FROM balance_snapshot
                    WHERE ts >= ?
                    ORDER BY provider_id, ts
                    """, arguments: [startMs])
                return fetched.map { row in
                    let providerId: String = row["provider_id"] ?? ""
                    let ts: Int64 = row["ts"] ?? 0
                    let balance: Double = row["balance"] ?? 0
                    let currency: String = row["currency"] ?? "USD"
                    return (providerId: providerId, ts: ts, balance: balance, currency: currency)
                }
            }

            var byProvider: [String: [(ts: Int64, balance: Double, currency: String)]] = [:]
            for row in rows {
                let pid = row.providerId
                byProvider[pid, default: []].append((row.ts, row.balance, row.currency))
            }

            var candidates: [SpendAlertPayload] = []
            for (pid, snapshots) in byProvider {
                guard snapshots.count >= 2,
                      let newest = snapshots.last,
                      let oldest = snapshots.first else { continue }

                let dropRaw = oldest.balance - newest.balance
                guard dropRaw > 0 else { continue }
                let dropUSD = dropRaw * StatsService.toUSD(currency: newest.currency)
                guard let level = SpendAlertRules.levelForBalanceDrop(
                    dropUSD: dropUSD, thresholds: thresholds) else { continue }

                candidates.append(SpendAlertPayload(
                    eventId: UUID().uuidString,
                    level: level.rawValue,
                    kind: SpendAlertKind.balanceDrop.rawValue,
                    source: pid,
                    amountUsd: dropUSD,
                    baselineUsd: nil,
                    occurredAt: now
                ))
            }
            return candidates
        } catch {
            Logger.error("SpendAlertService: balance check failed: \(error)")
            return []
        }
    }

    // MARK: - Dedupe & cooldown

    private func dedupeKey(_ payload: SpendAlertPayload) -> String {
        let bucket = Int(payload.occurredAt.timeIntervalSince1970 / 3600)
        return "\(payload.kind)-\(payload.source)-\(payload.level)-\(bucket)"
    }

    private func cooldown(for level: Int) -> TimeInterval {
        switch level {
        case 1: return 6 * 3600
        case 2: return 12 * 3600
        default: return 24 * 3600
        }
    }

    private func shouldFire(_ payload: SpendAlertPayload) -> Bool {
        let last = lastFired()[dedupeKey(payload)]
        return SpendAlertRules.shouldFire(
            lastFiredAt: last,
            cooldown: cooldown(for: payload.level),
            now: payload.occurredAt
        )
    }

    private func markFired(_ payload: SpendAlertPayload) {
        var dict = lastFired()
        dict[dedupeKey(payload)] = payload.occurredAt
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: lastFiredKey)
        }
    }

    private func lastFired() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: lastFiredKey),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return dict
    }

    // MARK: - Delivery

    private func deliver(_ payload: SpendAlertPayload) async {
        await CloudSyncService.shared.writeSpendAlert(payload)
        postLocalNotification(payload)
    }

    private func postLocalNotification(_ payload: SpendAlertPayload) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard SystemNotifications.isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = I18n.t("alert.l\(payload.level).title")
        content.body = alertBody(payload)
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "ai-pulse-spend-alert-\(payload.eventId)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func alertBody(_ payload: SpendAlertPayload) -> String {
        let amount = String(format: "$%.2f", payload.amountUsd)
        if let baseline = payload.baselineUsd {
            return String(format: I18n.t("alert.spend_rate.body"),
                          amount, String(format: "$%.2f", baseline))
        }
        return String(format: I18n.t("alert.balance_drop.body"), amount)
    }
}
