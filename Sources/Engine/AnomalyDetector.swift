import Foundation
import UserNotifications
import GRDB

/// Detects spending anomalies: if any hour's spend exceeds 3× the 7-day
/// hourly baseline, fires a macOS notification.
final class AnomalyDetector: @unchecked Sendable {
    static let shared = AnomalyDetector()
    private var notifiedHours = Set<Int>() // prevent duplicate alerts

    private init() {}

    /// Called periodically (e.g. after each ApiPoller cycle).
    func check() async {
        do {
            let cal = Calendar.current
            let now = Date()
            // Last 7 days of hourly spending
            let weekAgo = cal.date(byAdding: .day, value: -7, to: now)!
            let startMs = Int64(weekAgo.timeIntervalSince1970 * 1000)

            let rows = try await AppDatabase.shared.read { db -> [(hr: Int64, cost: Double)] in
                try Row.fetchAll(db, sql: """
                    SELECT (ts / 3600000) AS hr,
                           COALESCE(SUM(cost_usd), 0) AS c
                    FROM usage_event
                    WHERE ts >= ? AND (model IS NULL OR model != '<synthetic>')
                    GROUP BY hr ORDER BY hr DESC
                    """, arguments: [startMs]).map { row in
                    (hr: row["hr"] as Int64? ?? 0, cost: row["c"] as Double? ?? 0)
                }
            }

            guard rows.count >= 2 else { return }

            // Latest hour (just completed, or current partial)
            let latestRow = rows[0]
            let latestCost: Double = latestRow.cost

            // Baseline: average of all hours EXCEPT the latest
            let totalCost = rows.reduce(0.0) { $0 + $1.cost }
            let baseline = (totalCost - latestCost) / Double(rows.count - 1)
            let threshold = baseline * 3.0

            guard baseline > 0.005, latestCost >= threshold else {
                // Reset notified set periodically
                if notifiedHours.count > 48 { notifiedHours.removeAll() }
                return
            }

            let latestHrInt: Int64 = latestRow.hr
            let hourKey = Int(latestHrInt)
            if notifiedHours.contains(hourKey) { return }
            notifiedHours.insert(hourKey)

            await sendNotification(hour: hourKey, cost: latestCost, baseline: baseline)

        } catch {
            Logger.error("AnomalyDetector error: \(error)")
        }
    }

    private func sendNotification(hour: Int, cost: Double, baseline: Double) async {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard SystemNotifications.isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.alertSetting == .enabled else { return }

        let date = Date(timeIntervalSince1970: Double(hour * 3600))
        let fmt = DateFormatter(); fmt.dateFormat = "HH:00"

        let content = UNMutableNotificationContent()
        content.title = I18n.t("anomaly.title")
        content.body = String(format: I18n.t("anomaly.body"),
                              fmt.string(from: date),
                              String(format: "%.2f", cost),
                              String(format: "%.2f", baseline))
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "ai-pulse-anomaly-\(hour)",
            content: content, trigger: nil
        )
        try? await center.add(req)
    }
}
