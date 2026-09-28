import XCTest
import AIPulseShared

/// Deep links route notification taps and the iPhone widget into the app; the
/// range query must be strict so a stale or malformed link degrades to the
/// app default instead of breaking routing.
final class AIPulseDeepLinkTests: XCTestCase {
    func testPlainDashboardLinkHasNoRange() {
        let link = AIPulseDeepLink.parse(URL(string: "aipulse://dashboard")!)
        XCTAssertNotNil(link)
        XCTAssertNil(link?.range)
    }

    func testRangeLinkParsesEveryKnownRange() {
        for range in ["today", "week", "30d"] {
            let link = AIPulseDeepLink.parse(URL(string: "aipulse://dashboard?range=\(range)")!)
            XCTAssertEqual(link?.range, range)
        }
    }

    func testUnknownRangeDegradesToDefaultInsteadOfFailing() {
        let link = AIPulseDeepLink.parse(URL(string: "aipulse://dashboard?range=yesterday")!)
        XCTAssertNotNil(link, "an unknown range must still route to the dashboard")
        XCTAssertNil(link?.range)
    }

    func testNonDashboardLinksDoNotParse() {
        XCTAssertNil(AIPulseDeepLink.parse(URL(string: "aipulse://settings")!))
        XCTAssertNil(AIPulseDeepLink.parse(URL(string: "https://dashboard")!))
    }

    func testDebugSchemeMatches() {
        let link = AIPulseDeepLink.parse(URL(string: "aipulse-debug://dashboard?range=week")!)
        XCTAssertEqual(link?.range, "week")
        XCTAssertTrue(AIPulseDeepLink.opensDashboard(URL(string: "aipulse-debug://dashboard")!))
    }

    func testURLConstructionRoundTrips() {
        let url = AIPulseDeepLink.dashboardURL(for: "com.wxy.aipulse", range: "30d")
        XCTAssertEqual(url.absoluteString, "aipulse://dashboard?range=30d")
        XCTAssertEqual(AIPulseDeepLink.parse(url)?.range, "30d")

        let debugURL = AIPulseDeepLink.dashboardURL(for: "xingyu.wang.aipulse.debug", range: "today")
        XCTAssertEqual(debugURL.absoluteString, "aipulse-debug://dashboard?range=today")

        // Unknown range is dropped from the URL, not encoded.
        XCTAssertEqual(
            AIPulseDeepLink.dashboardURL(for: "com.wxy.aipulse", range: "week2").absoluteString,
            "aipulse://dashboard")
    }
}
