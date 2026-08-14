import Foundation

/// Decoded from the `SpendAlert_v1` record written by macOS.
struct SpendAlertPayload: Codable {
    var eventId: String
    var level: Int
    var kind: String
    var source: String
    var amountUsd: Double
    var baselineUsd: Double?
    var occurredAt: Date
}
