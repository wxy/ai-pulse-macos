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
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)

        do {
            // Today's balance-derived spend vs the median of the prior 7 local
            // calendar days. Same source as the Dashboard "Spend" chart, and
            // subscriptions are intentionally excluded.
            let daily = try await balanceDailyTotals(now: now)
            let today = daily[todayStart] ?? 0
            let baseline = Array(daily.filter { $0.key < todayStart }.values)
            // Don't fire on a cold start: a rate surge needs enough history to
            // establish what "normal" looks like, otherwise day one with a few
            // dollars of spend would look like a 2x surge over an empty median.
            guard baseline.count >= 3 else { return [] }
            let baselineMedian = SpendAlertRules.median(baseline)

            guard let level = SpendAlertRules.levelForSpendRate(
                current: today, baseline: baselineMedian, thresholds: thresholds)
            else { return [] }

            return [SpendAlertPayload(
                eventId: UUID().uuidString,
                level: level.rawValue,
                kind: SpendAlertKind.spendRate.rawValue,
                source: "aggregate",
                amountUsd: today,
                baselineUsd: baselineMedian,
                occurredAt: now
            )]
        } catch {
            Logger.error("SpendAlertService: rate check failed: \(error)")
            return []
        }
    }

    /// Local calendar-day balance-derived spend (USD) for the last 7 days plus
    /// today. Reuses `StatsService.balanceDailySpend`, the exact source behind
    /// the Dashboard "Spend" chart, so alert and Dashboard totals agree.
    private func balanceDailyTotals(now: Date) async throws -> [Date: Double] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: now)
        let firstDay = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        // One extra day of lookback captures the delta that straddles `firstDay`.
        let queryStart = cal.date(byAdding: .day, value: -1, to: firstDay) ?? firstDay

        let rows = try await StatsService.balanceDailySpend(
            days: 1,
            sinceMs: Int64(queryStart.timeIntervalSince1970 * 1000))

        var totals: [Date: Double] = [:]
        for row in rows where row.date >= firstDay {
            totals[row.date, default: 0] += row.spend
        }
        return totals
    }

    // MARK: - Balance drop

    private func balanceDropCandidates() async -> [SpendAlertPayload] {
        let now = Date()
        let dayMs = Int64(86_400_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let startMs = nowMs - dayMs

        do {
            let rows = try await AppDatabase.shared.read { db -> [(providerId: String, ts: Int64, balance: Double, currency: String)] in
                let fetched = try Row.fetchAll(db, sql: """
                    SELECT provider_id, ts, balance, currency
                    FROM balance_snapshot
                    WHERE ts >= ? AND ts <= ?
                    ORDER BY provider_id, ts
                    """, arguments: [startMs - dayMs, nowMs])
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
                guard let newest = snapshots.last,
                      let baseline = snapshots.last(where: { $0.ts <= startMs }) else { continue }

                // Measure from the last snapshot at-or-before the 24h boundary,
                // not the first snapshot inside the window. Otherwise the first
                // in-window snapshot already reflects part of the drop and the
                // 24h change is under-counted.
                let dropRaw = baseline.balance - newest.balance
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
