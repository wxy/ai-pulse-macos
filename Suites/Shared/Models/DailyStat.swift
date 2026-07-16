import Foundation

/// Daily-aggregated stats for the Dashboard charts.
struct DailyStat: Identifiable, Codable {
    var id: Date { date }
    let date: Date
    let cost: Double
    let calls: Int
    let tokens: Int
    let netLines: Int
    let costPerLine: Double
}

/// Daily code changes (added/deleted lines).
struct DailyCodeChange: Identifiable, Codable {
    var id: Date { date }
    let date: Date
    let added: Int
    let deleted: Int
}

/// Per-provider daily cost.
struct ProviderCost: Identifiable, Codable {
    var id: String { "\(providerId)-\(Int(date.timeIntervalSince1970))" }
    let date: Date
    let providerId: String
    let cost: Double
}
