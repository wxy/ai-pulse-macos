import WidgetKit
import SwiftUI
import Foundation

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry {
        WidgetEntry(
            todayCost: 3.50,
            weekCost: 18.20,
            monthCost: 72.80,
            yesterdaySpend: 2.80,
            dailyRate: 5.0,
            weeklyAvg: 35.0,
            monthProjected: 150.0,
            monthSoFar: 72.80,
            updatedAt: Date()
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        completion(placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        let entry = loadLatestEntry()
        let nextRefresh = Date().addingTimeInterval(3600)
        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }

    private func loadLatestEntry() -> WidgetEntry {
        guard let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.wxy.aipulse"
        ) else {
            return fallbackEntry()
        }
        let cacheURL = groupURL.appendingPathComponent("dashboard_cache.json")

        guard let data = try? Data(contentsOf: cacheURL),
              let dict = try? JSONDecoder().decode([String: DashboardSnapshot].self, from: data),
              let snap = dict["today"] ?? dict["week"] ?? dict["30d"]
        else {
            return fallbackEntry()
        }

        let dailyRate = max(snap.prediction?.dailyRate ?? 20, 0.01)
        return WidgetEntry(
            todayCost: snap.todayCost,
            weekCost: snap.weekCost,
            monthCost: snap.monthCost,
            yesterdaySpend: snap.yesterdaySpend,
            dailyRate: dailyRate,
            weeklyAvg: dailyRate * 7,
            monthProjected: snap.prediction?.monthProjected ?? 600,
            monthSoFar: snap.prediction?.monthSoFar ?? 0,
            updatedAt: snap.updatedAt
        )
    }

    private func fallbackEntry() -> WidgetEntry {
        WidgetEntry(
            todayCost: 0, weekCost: 0, monthCost: 0,
            yesterdaySpend: 0,
            dailyRate: 20, weeklyAvg: 140,
            monthProjected: 600, monthSoFar: 0,
            updatedAt: Date()
        )
    }
}

// MARK: - Entry

struct WidgetEntry: TimelineEntry {
    let date: Date
    let todayCost: Double
    let weekCost: Double
    let monthCost: Double
    let yesterdaySpend: Double
    let dailyRate: Double
    let weeklyAvg: Double
    let monthProjected: Double
    let monthSoFar: Double
    let updatedAt: Date

    init(todayCost: Double, weekCost: Double, monthCost: Double,
         yesterdaySpend: Double,
         dailyRate: Double, weeklyAvg: Double, monthProjected: Double,
         monthSoFar: Double, updatedAt: Date) {
        self.date = updatedAt
        self.todayCost = todayCost
        self.weekCost = weekCost
        self.monthCost = monthCost
        self.yesterdaySpend = yesterdaySpend
        self.dailyRate = dailyRate
        self.weeklyAvg = weeklyAvg
        self.monthProjected = monthProjected
        self.monthSoFar = monthSoFar
        self.updatedAt = updatedAt
    }
}

// MARK: - Widget

struct AIPulseWidget: Widget {
    let kind: String = "AIPulseWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            AIPulseWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("AI Pulse")
        .description("Track your AI coding spend at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
        ])
        .contentMarginsDisabled()
    }
}
