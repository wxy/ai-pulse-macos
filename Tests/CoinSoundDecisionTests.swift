import XCTest
@testable import AIPulse
import AIPulseShared

final class CoinSoundDecisionTests: XCTestCase {

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(h: Int, m: Int = 0) -> Date {
        utcCalendar().date(from: DateComponents(year: 2026, month: 9, day: 11, hour: h, minute: m))!
    }

    private func settings(enabled: Bool = true,
                          quietEnabled: Bool = true,
                          from: Int = 22 * 60, to: Int = 8 * 60,
                          maxPerHour: Int = 8) -> SoundSettings {
        SoundSettings(enabled: enabled, volume: 0.5, quietEnabled: quietEnabled,
                      quietFromMinutes: from, quietToMinutes: to,
                      maxPerHour: maxPerHour, pack: "default")
    }

    private func event(spend: Double? = nil, tokens: Int? = nil) -> ConsumptionEvent {
        ConsumptionEvent(spendUSD: spend, tokens: tokens, source: "test")
    }

    private func pulse(_ tier: PulseTier, at date: Date) -> PulseSnapshot {
        PulseSnapshot(tier: tier, primarySignal: .activity,
                      reason: "test", signals: [], asOf: date)
    }

    // MARK: - Quiet hours (防烦原则 2, cross-midnight aware)

    func testChimesDoNotDependOnConsumptionToggle() {
        let s = settings(enabled: false)
        XCTAssertTrue(CoinSound.permitsPlayback(.chime, settings: s))
        XCTAssertFalse(CoinSound.permitsPlayback(.coin, settings: s))
        XCTAssertFalse(CoinSound.permitsPlayback(.coinRain, settings: s))
    }

    func testGlobalMuteBlocksAllCueTypes() {
        var s = settings()
        s.muted = true
        for cue: SoundDecision in [.coin, .coinDouble, .coinRain, .chime] {
            XCTAssertFalse(CoinSound.permitsPlayback(cue, settings: s))
        }
    }

    func testQuietHoursCrossMidnight() {
        let s = settings() // 22:00 → 08:00
        let cal = utcCalendar()
        XCTAssertTrue(CoinSound.isQuietTime(date(h: 23), settings: s, calendar: cal))
        XCTAssertTrue(CoinSound.isQuietTime(date(h: 3, m: 59), settings: s, calendar: cal))
        XCTAssertFalse(CoinSound.isQuietTime(date(h: 8), settings: s, calendar: cal), "end is exclusive")
        XCTAssertFalse(CoinSound.isQuietTime(date(h: 12), settings: s, calendar: cal))
        XCTAssertTrue(CoinSound.isQuietTime(date(h: 22), settings: s, calendar: cal), "start is inclusive")
    }

    func testZeroLengthQuietWindowMeansOff() {
        let s = settings(from: 600, to: 600)
        XCTAssertFalse(CoinSound.isQuietTime(date(h: 10), settings: s, calendar: utcCalendar()))
    }

    func testQuietHoursDiscardEventsInsteadOfReplayingThem() {
        let s = settings()
        let cal = utcCalendar()
        let state0 = CoinSound.DecisionState()
        // 23:30 — quiet: no sound and no deferred amount.
        let (d1, s1) = CoinSound.decide(events: [event(spend: 0.8)], pulse: nil,
                                        settings: s, state: state0, now: date(h: 23, m: 30), calendar: cal)
        XCTAssertEqual(d1, SoundDecision.none)
        // 09:00 — only the fresh event is considered.
        let (d2, _) = CoinSound.decide(events: [event(spend: 0.5)], pulse: nil,
                                       settings: s, state: s1, now: date(h: 9), calendar: cal)
        XCTAssertEqual(d2, .coin)
    }

    // MARK: - Absolute hourly cap (防烦原则 1)

    func testHourlyCapBlocksBeyondLimit() {
        let s = settings(quietEnabled: false, maxPerHour: 2)
        var state = CoinSound.DecisionState()
        let t0 = date(h: 12)
        // Play #1
        (state = CoinSound.decide(events: [event(spend: 0.05)], pulse: nil, settings: s,
                                  state: state, now: t0).state)
        // Play #2 (10 min later, past the 90s merge window)
        (state = CoinSound.decide(events: [event(spend: 0.05)], pulse: nil, settings: s,
                                  state: state, now: t0.addingTimeInterval(600)).state)
        // Play #3 blocked — cap reached
        let (d3, s3) = CoinSound.decide(events: [event(spend: 0.05)], pulse: nil, settings: s,
                                        state: state, now: t0.addingTimeInterval(1200))
        XCTAssertEqual(d3, SoundDecision.none)
        // 61.7 min later: play #1 aged out of the 1h cap window → allowed again.
        let (d4, _) = CoinSound.decide(events: [event(spend: 0.05)], pulse: nil, settings: s,
                                       state: s3, now: t0.addingTimeInterval(3_700))
        XCTAssertEqual(d4, SoundDecision.coin)
    }

    // MARK: - Merge window scales with burn tier

    func testMergeWindowSuppressesWithoutAccumulatingAmounts() {
        let s = settings(quietEnabled: false)
        let t0 = date(h: 12)
        // Normal tier: 90s merge window
        let (d1, s1) = CoinSound.decide(events: [event(spend: 0.6)], pulse: nil,
                                        settings: s, state: .init(), now: t0)
        XCTAssertEqual(d1, .coin)
        // Within the window: suppressed and discarded.
        let (d2, s2) = CoinSound.decide(events: [event(spend: 0.6)], pulse: nil,
                                        settings: s, state: s1, now: t0.addingTimeInterval(30))
        XCTAssertEqual(d2, SoundDecision.none)
        // After the window: fresh activity produces one regular beat.
        let (d3, _) = CoinSound.decide(events: [event(spend: 0.5)], pulse: nil,
                                       settings: s, state: s2, now: t0.addingTimeInterval(100))
        XCTAssertEqual(d3, SoundDecision.coin)
    }

    func testBlazeTierShortensMergeWindow() {
        let s = settings(quietEnabled: false)
        let t0 = date(h: 12)
        let intense = pulse(.intense, at: t0)
        let (_, s1) = CoinSound.decide(events: [event(spend: 0.05)], pulse: intense,
                                       settings: s, state: .init(), now: t0)
        // Intense window is 30s → at +31s a new pulse beat is allowed.
        let (d, _) = CoinSound.decide(events: [event(spend: 0.05)], pulse: intense,
                                      settings: s, state: s1, now: t0.addingTimeInterval(31))
        XCTAssertEqual(d, SoundDecision.coinRain)
    }

    // MARK: - Pulse grading (raw amounts never grade sound)

    func testGradingByPulseTierNotSpendAmount() {
        let s = settings(quietEnabled: false)
        let t0 = date(h: 12)
        func grade(_ tier: PulseTier, spend: Double?) -> SoundDecision {
            let (d, _) = CoinSound.decide(
                events: [event(spend: spend)], pulse: pulse(tier, at: t0),
                settings: s, state: .init(), now: t0)
            return d
        }
        XCTAssertEqual(grade(.active, spend: 5), .coin)
        XCTAssertEqual(grade(.elevated, spend: 0.01), .coinDouble)
        XCTAssertEqual(grade(.intense, spend: nil), .coinRain)
    }

    func testTierEscalationBreaksThroughMergeWindow() {
        let s = settings(quietEnabled: false)
        let t0 = date(h: 12)
        let (_, state) = CoinSound.decide(
            events: [event(tokens: 1)], pulse: pulse(.active, at: t0),
            settings: s, state: .init(), now: t0)
        let (decision, _) = CoinSound.decide(
            events: [event(tokens: 1)], pulse: pulse(.intense, at: t0),
            settings: s, state: state, now: t0.addingTimeInterval(1))
        XCTAssertEqual(decision, .coinRain)
    }

    func testTokenOnlyEventsStillRing() {
        let (d, _) = CoinSound.decide(events: [event(tokens: 42_000)], pulse: nil,
                                      settings: settings(quietEnabled: false),
                                      state: .init(), now: date(h: 12))
        XCTAssertEqual(d, SoundDecision.coin)
    }

    func testDisabledMeansSilence() {
        let (d, _) = CoinSound.decide(events: [event(spend: 5.0)], pulse: nil,
                                      settings: settings(enabled: false),
                                      state: .init(), now: date(h: 12))
        XCTAssertEqual(d, SoundDecision.none)
    }

    func testMasterMuteMeansSilenceWithoutChangingCoinPreference() {
        var s = settings(enabled: true, quietEnabled: false)
        s.muted = true
        let (decision, _) = CoinSound.decide(
            events: [event(tokens: 42_000)], pulse: pulse(.intense, at: date(h: 12)),
            settings: s, state: .init(), now: date(h: 12))
        XCTAssertEqual(decision, .none)
        XCTAssertTrue(s.enabled)
    }

    func testMasterMutePersistsIndependently() {
        let suite = "CoinSoundDecisionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AppSoundControl.setMuted(true, defaults: defaults)

        XCTAssertTrue(AppSoundControl.isMuted(defaults: defaults))
        XCTAssertTrue(SoundSettings.current(defaults: defaults).muted)
    }

    // MARK: - Settings parsing

    func testParseHM() {
        XCTAssertEqual(SoundSettings.parseHM("22:00"), 1320)
        XCTAssertEqual(SoundSettings.parseHM("08:30"), 510)
        XCTAssertEqual(SoundSettings.parseHM("9:05"), 545, "single-digit hour tolerated")
        XCTAssertNil(SoundSettings.parseHM("24:00"))
        XCTAssertNil(SoundSettings.parseHM("ab:cd"))
        XCTAssertNil(SoundSettings.parseHM("1200"))
    }
}
