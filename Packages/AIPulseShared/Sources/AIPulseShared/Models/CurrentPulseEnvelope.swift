import Foundation

/// Independent current observation. Historical period snapshots never carry
/// this value. Expired observations remain history, not a current resting tier.
public struct CurrentPulseEnvelope: Codable, Sendable {
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

    public func currentPulse(asOf now: Date = Date()) -> PulseSnapshot? {
        guard payloadVersion == CKSchema.payloadVersion, generatedAt <= now,
              pulse?.isCurrent(asOf: now) == true else { return nil }
        return pulse
    }
}
