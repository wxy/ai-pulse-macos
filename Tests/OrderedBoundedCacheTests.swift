import XCTest
@testable import AIPulse

/// 2026-10-23 review F07:超容量后的全表清空让稳定历史每 30 秒整表重读。
/// 稳定历史必须能抵抗顺序扫描污染,同时为近期文件保留准入空间。
final class OrderedBoundedCacheTests: XCTestCase {
    func testSurvivesBeyondCapacityWithoutFullClear() {
        let cache = OrderedBoundedCache<Int>(capacity: 8)
        for i in 0..<100 { cache.insert(i, for: "k\(i)") }

        // A stable protected segment survives a stream of one-off files.
        for i in 0..<6 {
            XCTAssertEqual(cache.value(for: "k\(i)"), i)
        }
        XCTAssertEqual(cache.value(for: "k99"), 99)
        XCTAssertLessThanOrEqual(cache.count, 8)
    }

    func testEvictionIsSelectiveNotWholeTable() {
        let cache = OrderedBoundedCache<String>(capacity: 4)
        cache.insert("a", for: "a")
        cache.insert("b", for: "b")
        cache.insert("c", for: "c")
        cache.insert("d", for: "d")
        cache.insert("e", for: "e")

        // New arrivals rotate through the window rather than flushing the
        // protected history before the next sequential scan reaches it.
        XCTAssertEqual(cache.value(for: "a"), "a")
        XCTAssertEqual(cache.value(for: "b"), "b")
        XCTAssertEqual(cache.value(for: "c"), "c")
        XCTAssertNil(cache.value(for: "d"))
        XCTAssertEqual(cache.value(for: "e"), "e")
    }

    func testReinsertRefreshesRecencyAndValue() {
        let cache = OrderedBoundedCache<Int>(capacity: 4)
        for i in 0..<4 { cache.insert(i, for: "k\(i)") }
        cache.insert(100, for: "k0") // re-read: new value, fresh recency

        for i in 4..<7 { cache.insert(i, for: "k\(i)") }
        XCTAssertEqual(cache.value(for: "k0"), 100)
        XCTAssertEqual(cache.value(for: "k1"), 1)
        XCTAssertEqual(cache.value(for: "k2"), 2)
        XCTAssertNil(cache.value(for: "k3"))
        XCTAssertNil(cache.value(for: "k4"))
        XCTAssertNil(cache.value(for: "k5"))
        XCTAssertEqual(cache.value(for: "k6"), 6)
    }

    func testOverwritingExistingKeyDoesNotEvict() {
        let cache = OrderedBoundedCache<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "b") // update in place: no capacity crossing
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "b"), 3)
    }

    func testSingleEntryCapacityEvictsOldestEachInsert() {
        let cache = OrderedBoundedCache<Int>(capacity: 1)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), nil)
        XCTAssertEqual(cache.value(for: "b"), 2)
        XCTAssertEqual(cache.count, 1)
    }
}
