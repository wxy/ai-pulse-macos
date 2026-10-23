import XCTest
@testable import AIPulse

/// 2026-10-23 review F07:超容量后的全表清空让稳定历史每 30 秒整表重读。
/// 选择性驱逐必须保住未驱逐条目的命中,并且重插获得新的新近度。
final class OrderedBoundedCacheTests: XCTestCase {
    func testSurvivesBeyondCapacityWithoutFullClear() {
        let cache = OrderedBoundedCache<Int>(capacity: 8)
        for i in 0..<100 { cache.insert(i, for: "k\(i)") }

        // Steady state keeps the newest slice (≥ capacity - evictionBatch)
        // entries; a full clear would have evicted everything at the first
        // capacity crossing and re-read the whole table every pass.
        for i in 94..<100 {
            XCTAssertEqual(cache.value(for: "k\(i)"), i)
        }
        XCTAssertNil(cache.value(for: "k0"))
        XCTAssertLessThanOrEqual(cache.count, 8)
    }

    func testEvictionIsSelectiveNotWholeTable() {
        let cache = OrderedBoundedCache<String>(capacity: 4)
        cache.insert("a", for: "a")
        cache.insert("b", for: "b")
        cache.insert("c", for: "c")
        cache.insert("d", for: "d")
        cache.insert("e", for: "e") // crossing: evicts the oldest quarter

        // Eviction batch = capacity / 4 = 1 → the oldest entry drops, the
        // rest of the table survives untouched.
        XCTAssertNil(cache.value(for: "a"))
        XCTAssertEqual(cache.value(for: "b"), "b")
        XCTAssertEqual(cache.value(for: "c"), "c")
        XCTAssertEqual(cache.value(for: "d"), "d")
        XCTAssertEqual(cache.value(for: "e"), "e")
    }

    func testReinsertRefreshesRecencyAndValue() {
        let cache = OrderedBoundedCache<Int>(capacity: 4)
        for i in 0..<4 { cache.insert(i, for: "k\(i)") }
        cache.insert(100, for: "k0") // re-read: new value, fresh recency

        // Three capacity crossings evict the three oldest originals one by
        // one (k1, k2, k3) while the re-inserted k0 — now the newest stamp —
        // survives every pass.
        for i in 4..<7 { cache.insert(i, for: "k\(i)") }
        XCTAssertEqual(cache.value(for: "k0"), 100)
        XCTAssertNil(cache.value(for: "k1"))
        XCTAssertNil(cache.value(for: "k2"))
        XCTAssertNil(cache.value(for: "k3"))
        XCTAssertEqual(cache.value(for: "k4"), 4)
        XCTAssertEqual(cache.value(for: "k5"), 5)
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
