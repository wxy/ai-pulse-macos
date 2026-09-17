import XCTest
@testable import AIPulse

private final class LockedNotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func read() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class DataRefreshCoordinatorTests: XCTestCase {

    var coordinator: DataRefreshCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = DataRefreshCoordinator(actions: .noop, playConsumption: { _, _ in })
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

        let notificationCount = LockedNotificationCounter()
        let beatCount = LockedNotificationCounter()
        let beatObserver = NotificationCenter.default.addObserver(
            forName: .consumptionDidOccur, object: nil, queue: .main
        ) { _ in _ = beatCount.increment() }
        defer { NotificationCenter.default.removeObserver(beatObserver) }
        let observer = NotificationCenter.default.addObserver(
            forName: .dataDidChange, object: nil, queue: .main
        ) { _ in
            _ = notificationCount.increment()
            expectation.fulfill()
        }

        // Simulate rapid-fire changes from multiple phases
        coordinator.notifyPhaseIngest()
        coordinator.notifyPhaseGitScan()
        coordinator.notifyPhaseBalance()

        wait(for: [expectation], timeout: 3.0)

        // After 500ms debounce, only one notification should have fired
        // (but by the time we check, at most 1 should fire due to 3s min interval)
        XCTAssertEqual(notificationCount.read(), 1, "Rapid pushes should coalesce to one notification")
        XCTAssertEqual(beatCount.read(), 0, "Generic refreshes must not manufacture a consumption beat")

        NotificationCenter.default.removeObserver(observer)
    }

    func testNonemptyConsumptionBatchProducesOneExplicitBeat() {
        let beat = XCTestExpectation(description: "Observed consumption beat")
        let counter = LockedNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .consumptionDidOccur, object: nil, queue: .main
        ) { _ in
            _ = counter.increment()
            beat.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        coordinator.notifyPhaseIngest(ConsumptionEvent(spendUSD: nil, tokens: 100, source: "codex"))
        coordinator.notifyPhaseGitScan()
        wait(for: [beat], timeout: 3)
        XCTAssertEqual(counter.read(), 1)
    }

    // MARK: - Min-notify interval delivery

    func testMinNotifyIntervalDelaysButDoesNotLoseSecondNotification() {
        // Fire two notifications within the min interval. The second should wait,
        // then arrive without requiring a third unrelated event.
        let firstExpectation = XCTestExpectation(description: "First .dataDidChange fires")
        let secondExpectation = XCTestExpectation(description: "Delayed .dataDidChange fires")

        let notificationCount = LockedNotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: .dataDidChange, object: nil, queue: .main
        ) { _ in
            let count = notificationCount.increment()
            if count == 1 { firstExpectation.fulfill() }
            if count == 2 { secondExpectation.fulfill() }
        }

        // First push — should fire after 500ms debounce
        coordinator.notifyPhaseIngest()

        wait(for: [firstExpectation], timeout: 2.0)

        // Second push within the 3s min interval — should be delayed.
        coordinator.notifyPhaseGitScan()

        wait(for: [secondExpectation], timeout: 4.0)
        XCTAssertEqual(notificationCount.read(), 2, "Delayed push must eventually be delivered")

        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: - notifyDataChange is callable

    func testNotifyDataChangeDoesNotCrash() {
        coordinator.notifyDataChange()
    }
}
