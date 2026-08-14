import XCTest
@testable import AIPulse

final class DataRefreshCoordinatorTests: XCTestCase {

    var coordinator: DataRefreshCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = DataRefreshCoordinator(actions: .noop)
    }

    override func tearDown() {
        coordinator.stop()
        super.tearDown()
    }

    // MARK: - Lifecycle

    func testStartAndStopDoesNotCrash() {
        coordinator.start()
        coordinator.stop()
    }

    func testStartTwiceDoesNotCrash() {
        coordinator.start()
        coordinator.start()
        coordinator.stop()
    }

    // MARK: - Trigger ingest

    func testTriggerIngestRunsWithoutStart() {
        // Should not crash — dispatches to notifyQueue
        coordinator.triggerIngest()
    }

    // MARK: - Debounce coalesces rapid pushes

    func testRapidPhasePushesAreDebounced() {
        let expectation = XCTestExpectation(description: "dataDidChange fires once after debounce")
        expectation.expectedFulfillmentCount = 1
        expectation.assertForOverFulfill = true

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .dataDidChange, object: nil, queue: .main
        ) { _ in
            notificationCount += 1
            expectation.fulfill()
        }

        // Simulate rapid-fire changes from multiple phases
        coordinator.notifyPhaseIngest()
        coordinator.notifyPhaseGitScan()
        coordinator.notifyPhaseBalance()

        wait(for: [expectation], timeout: 3.0)

        // After 500ms debounce, only one notification should have fired
        // (but by the time we check, at most 1 should fire due to 3s min interval)
        XCTAssertEqual(notificationCount, 1, "Rapid pushes should coalesce to one notification")

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - Min-notify interval suppression

    func testMinNotifyIntervalSuppressesRapidNotifications() {
        // Fire two notifications within the min interval — only the first should post
        let firstExpectation = XCTestExpectation(description: "First .dataDidChange fires")

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .dataDidChange, object: nil, queue: .main
        ) { _ in
            notificationCount += 1
            firstExpectation.fulfill()
        }

        // First push — should fire after 500ms debounce
        coordinator.notifyPhaseIngest()

        wait(for: [firstExpectation], timeout: 2.0)

        // Second push within the 3s min interval — should be suppressed
        coordinator.notifyPhaseGitScan()

        // Wait a bit to ensure no extra notification fires
        let waitExpectation = XCTestExpectation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            waitExpectation.fulfill()
        }
        wait(for: [waitExpectation], timeout: 2.0)

        // The second push should have been suppressed (within 3s interval)
        // but 1s wait + 500ms debounce means it may or may not have fired yet.
        // Key assertion: notificationCount should be 1 (the first one).
        XCTAssertEqual(notificationCount, 1, "Second push within 3s should be suppressed")

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - notifyDataChange is callable

    func testNotifyDataChangeDoesNotCrash() {
        coordinator.notifyDataChange()
    }
}
