import XCTest
import AIPulseShared

final class CurrentPulseEnvelopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)

    func testCloudObservationSurvivesNextPublishCycleAndStillExpires() {
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "activity", signals: [], asOf: now)
        let envelope = CurrentPulseEnvelope.forCloudSync(pulse: pulse, writerAppVersion: "2.0.0", generatedAt: now)
        XCTAssertEqual(envelope.currentPulse(asOf: now.addingTimeInterval(360))?.tier, .active)
        XCTAssertNil(envelope.currentPulse(asOf: now.addingTimeInterval(420)))
        XCTAssertFalse(pulse.isCurrent(asOf: now.addingTimeInterval(60)))
    }

    func testCloudPublisherDoesNotReviveExpiredLocalObservation() {
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "activity", signals: [], asOf: now)
        let envelope = CurrentPulseEnvelope.forCloudSync(pulse: pulse, writerAppVersion: "2.0.0", generatedAt: now.addingTimeInterval(60))
        XCTAssertNil(envelope.pulse)
    }

    func testCurrentPulseExpiresRatherThanPretendingToBeResting() {
        let pulse = PulseSnapshot(tier: .intense, primarySignal: .activity, reason: "activity", signals: [], asOf: now)
        let envelope = CurrentPulseEnvelope(pulse: pulse, writerAppVersion: "2.0.0", generatedAt: now)
        XCTAssertEqual(envelope.currentPulse(asOf: now.addingTimeInterval(59))?.tier, .intense)
        XCTAssertNil(envelope.currentPulse(asOf: now.addingTimeInterval(60)))
        XCTAssertNil(envelope.currentPulse(asOf: now.addingTimeInterval(-1)))
    }

    func testValidRestingAndMissingObservationAreDifferent() throws {
        let resting = PulseSnapshot(tier: .resting, primarySignal: nil, reason: "no_recent_signal", signals: [], asOf: now)
        let envelope = CurrentPulseEnvelope(pulse: resting, writerAppVersion: "2.0.0", generatedAt: now)
        XCTAssertEqual(envelope.currentPulse(asOf: now)?.tier, .resting)
        let unknown = CurrentPulseEnvelope(pulse: nil, writerAppVersion: "2.0.0", generatedAt: now)
        XCTAssertNil(unknown.currentPulse(asOf: now))
        let decoded = try JSONDecoder().decode(CurrentPulseEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(decoded.currentPulse(asOf: now), resting)
    }

    func testSanitizesCurrentSignalsAtItsOwnBoundary() {
        let pulse = PulseSnapshot(tier: .active, primarySignal: .activity, reason: "activity",
            signals: [PulseSignal(kind: .activity, rawValue: .nan, unit: "tokens/h", baseline: -.infinity,
                                  normalized: .infinity, freshness: .fresh, completeness: .partial,
                                  observedAt: now, reason: "activity")], asOf: now)
        let clean = CurrentPulseEnvelope(pulse: pulse, writerAppVersion: "2.0.0", generatedAt: now)
        XCTAssertEqual(clean.pulse?.activity?.rawValue, 0)
        XCTAssertEqual(clean.pulse?.activity?.baseline, 0)
        XCTAssertEqual(clean.pulse?.activity?.normalized, 0)
    }

    func testExactActivityFactsRoundTripWithoutTurningMalformedFactsIntoZero() throws {
        let facts = PulseActivityFacts(recentTokens: 350_000, todayTokens: 2_400_000, isPartial: true)
        var pulse = PulseSnapshot(tier: .elevated, primarySignal: .activity, reason: "activity",
                                  signals: [], asOf: now, activityFacts: facts)
        let decoded = try JSONDecoder().decode(PulseSnapshot.self, from: JSONEncoder().encode(pulse))
        XCTAssertEqual(decoded.activityFacts, facts)
        pulse.activityFacts?.recentTokens = -1
        XCTAssertNil(pulse.sanitized().activityFacts)
    }
}
