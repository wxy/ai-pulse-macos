import Foundation

/// Independent current observation. Historical period snapshots never carry
/// this value. Expired observations remain history, not a current resting tier.
public struct CurrentPulseEnvelope: Codable, Sendable {
    public static let publisherInterval: TimeInterval = 5 * 60
    public static let widgetRefreshInterval: TimeInterval = 15 * 60
    public static let deliveryTolerance: TimeInterval = 2 * 60
    public static let cloudValidityInterval = publisherInterval + widgetRefreshInterval + deliveryTolerance

    public let payloadVersion: String
    public let writerAppVersion: String
    public let generatedAt: Date
    public let pulse: PulseSnapshot?

    public init(pulse: PulseSnapshot?, writerAppVersion: String, generatedAt: Date = Date()) {
        payloadVersion = CKSchema.payloadVersion
        self.writerAppVersion = writerAppVersion
        self.generatedAt = generatedAt
        self.pulse = pulse?.sanitized()
    }

    /// Keep a published observation current across one five-minute publisher
    /// interval, one nominal widget refresh interval, and delivery tolerance.
    /// Extend only an observation that is current at publication time; never
    /// revive a stale local observation. Local validity remains unchanged.
    public static func forCloudSync(pulse: PulseSnapshot?, writerAppVersion: String,
                                    generatedAt: Date = Date()) -> Self {
        var observation = pulse?.isCurrent(asOf: generatedAt) == true ? pulse : nil
        observation?.validUntil = generatedAt.addingTimeInterval(cloudValidityInterval)
        return Self(pulse: observation, writerAppVersion: writerAppVersion, generatedAt: generatedAt)
    }

    public func currentPulse(asOf now: Date = Date()) -> PulseSnapshot? {
        guard payloadVersion == CKSchema.payloadVersion, generatedAt <= now,
              pulse?.isCurrent(asOf: now) == true else { return nil }
        return pulse
    }
}
