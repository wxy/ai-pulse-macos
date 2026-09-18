import XCTest
import AIPulseShared
@testable import AIPulse

private actor DeferredPulseSource {
    private var requests: [Int: CheckedContinuation<PulseSnapshot?, Never>] = [:]
    private(set) var count = 0

    func load() async -> PulseSnapshot? {
        let id = count
        count += 1
        return await withCheckedContinuation { requests[id] = $0 }
    }

    func resolve(_ id: Int, with pulse: PulseSnapshot?) {
        requests.removeValue(forKey: id)?.resume(returning: pulse)
    }
}

final class PulsePresentationTests: XCTestCase {
    @MainActor
    private func waitForRequests(_ count: Int, from source: DeferredPulseSource) async throws {
        for _ in 0..<10_000 {
            if await source.count >= count { return }
            await Task.yield()
        }
        XCTFail("Presentation request did not start")
        throw NSError(domain: "PulsePresentationTests", code: 1)
    }

    @MainActor
    func testBothRenderersReceiveOnePublishedSnapshotAndOldCompletionCannotReplaceIt() async throws {
        let source = DeferredPulseSource()
        let presentation = PulseFeedbackController(loadSnapshot: { await source.load() })
        presentation.start()
        defer { presentation.stop() }
        try await waitForRequests(1, from: source)
        let newer = Task { await presentation.refresh() }
        try await waitForRequests(2, from: source)
        let now = Date()
        let latest = PulseSnapshot(tier: .intense, primarySignal: .activity,
                                   reason: "latest", signals: [], asOf: now)
        await source.resolve(1, with: latest)
        await newer.value
        XCTAssertEqual(presentation.snapshot, latest)
        await source.resolve(0, with: PulseSnapshot(tier: .active, primarySignal: .activity,
                                                   reason: "old", signals: [], asOf: now))
        await Task.yield()
        XCTAssertEqual(presentation.snapshot, latest)
        XCTAssertFalse(presentation.isBeating, "Publishing a state is not new consumption")
    }

    @MainActor
    func testStopInvalidatesPendingStatePublication() async throws {
        let source = DeferredPulseSource()
        let presentation = PulseFeedbackController(loadSnapshot: { await source.load() })
        presentation.start()
        try await waitForRequests(1, from: source)
        presentation.stop()
        await source.resolve(0, with: PulseSnapshot(tier: .intense, primarySignal: .activity,
                                                   reason: "late", signals: [], asOf: Date()))
        await Task.yield()
        XCTAssertNil(presentation.snapshot)
        XCTAssertFalse(presentation.isBeating)
    }

    func testColdStartCopyNeverClaimsPersonalHistory() {
        XCTAssertEqual(PulseCopy.localizedReason("token_rate_cold_start_3_4x"),
                       I18n.t("pulse.activity.reference"))
    }

    func testCompiledResourcesRenderFactsAndComparisonArguments() {
        XCTAssertNotEqual(I18n.t("pulse.activity.recent"), "pulse.activity.recent")
        let facts = PulseActivityFacts(recentTokens: 350_000, todayTokens: 2_400_000)
        XCTAssertTrue(PulseCopy.recentFacts(facts).contains("350.0K"))
        XCTAssertTrue(PulseCopy.todayFacts(facts, commits: 8).contains("2.4M"))
        XCTAssertTrue(PulseCopy.todayFacts(facts, commits: nil).contains("—"))
        XCTAssertTrue(PulseCopy.localizedReason("token_rate_2_7x").contains("2.7"))
    }

    func testQuotaContextKeepsMissingEmptyAndExpiredSeparate() {
        let now = Date()
        let item = QuotaStatusItem(toolId: "codex", windowId: "5h", utilization: 96,
                                  limitStatus: "allowed", resetAt: now.timeIntervalSince1970 + 60,
                                  windowSeconds: 18_000, updatedAt: now.timeIntervalSince1970)
        XCTAssertNil(StatusItemController.quotaContext(items: [], now: now))
        XCTAssertEqual(StatusItemController.quotaContext(items: nil, now: now), I18n.t("pulse.activity.quota_unavailable"))
        XCTAssertTrue(StatusItemController.quotaContext(items: [item], now: now)?.contains("96.0%") == true)
        XCTAssertEqual(StatusItemController.quotaContext(items: [item], now: now.addingTimeInterval(61)),
                       I18n.t("pulse.activity.quota_stale"))
    }

    func testNewStateAndFactStringsExistInAllSupportedLanguagesWithValidFormats() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Sources/Localizable.xcstrings"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(document["strings"] as? [String: [String: Any]])
        let keys = ["pulse.tier.unknown", "pulse.tier.resting", "pulse.tier.active", "pulse.tier.elevated", "pulse.tier.intense",
                    "pulse.activity.reference", "pulse.activity.personal", "pulse.activity.recent", "pulse.activity.today",
                    "pulse.activity.partial", "pulse.activity.recent_signal", "pulse.activity.quota_context",
                    "pulse.activity.quota_stale", "pulse.activity.quota_unavailable", "pulse.activity.legend",
                    "pulse.activity.cooling", "dashboard.tool_tokens", "dashboard.repo_code_changes",
                    "dashboard.repo_code_changes_help", "dashboard.code_composition_help",
                    "dashboard.account_observations", "dashboard.quota_context_title",
                    "dashboard.fixed_monthly_context", "dashboard.fixed_monthly_help",
                    "panel.back_to_dashboard", "panel.open_tool_detail", "dashboard.local_activity_scope",
                    "dashboard.scan_warning_help", "dashboard.lines_unit"]
        for key in keys {
            let entry = try XCTUnwrap(strings[key])
            let locales = try XCTUnwrap(entry["localizations"] as? [String: [String: Any]])
            for language in I18n.supportedLanguages.map(\.code).filter({ $0 != "auto" }) {
                let locale = try XCTUnwrap(locales[language], "\(key): \(language)")
                let unit = try XCTUnwrap(locale["stringUnit"] as? [String: String])
                let text = try XCTUnwrap(unit["value"])
                XCTAssertFalse(text.isEmpty)
                XCTAssertEqual(unit["state"], "translated")
                if key == "pulse.tier.active" {
                    if language == "fr" { XCTAssertEqual(text, "Activité en cours") }
                    if language == "es" { XCTAssertEqual(text, "Actividad en curso") }
                }
                if key == "panel.open_tool_detail" {
                    XCTAssertTrue(String(format: text, "Codex").contains("Codex"))
                } else if key == "pulse.activity.recent" {
                    let formatted = String(format: text, 10, "350K")
                    XCTAssertTrue(formatted.contains("10"))
                    XCTAssertTrue(formatted.contains("350K"))
                } else if key == "pulse.activity.today" {
                    let formatted = String(format: text, "2.4M", "8")
                    XCTAssertTrue(formatted.contains("2.4M"))
                    XCTAssertTrue(formatted.contains("8"))
                } else if key == "pulse.activity.personal" {
                    XCTAssertTrue(String(format: text, "2.7").contains("2.7"))
                }
            }
        }
    }
}
