import Foundation

/// Decoded from the `SpendAlert_v1` record written by macOS.
public struct SpendAlertPayload: Codable, Sendable {
    public var eventId: String
    public var level: Int
    public var kind: String
    public var source: String
    public var amountUsd: Double
    public var baselineUsd: Double?
    public var occurredAt: Date

    public init(
        eventId: String,
        level: Int,
        kind: String,
        source: String,
        amountUsd: Double,
        baselineUsd: Double?,
        occurredAt: Date
    ) {
        self.eventId = eventId
        self.level = level
        self.kind = kind
        self.source = source
        self.amountUsd = amountUsd
        self.baselineUsd = baselineUsd
        self.occurredAt = occurredAt
    }
}
