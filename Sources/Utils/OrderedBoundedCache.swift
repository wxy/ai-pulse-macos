import Foundation

/// Insertion-ordered bounded cache (2026-10-23 review F07).
///
/// The previous policy cleared the whole table once it exceeded its capacity.
/// With a history larger than the capacity, one steady-state pass re-inserted
/// every entry and the next pass re-read and re-parsed every file again —
/// the 4KB head reads the cache exists to prevent came back forever.
///
/// Exceeding capacity now evicts only the oldest quarter. Unchanged entries
/// that survive keep hitting their fingerprint, so a pass over a large,
/// stable history re-reads just the evicted slice (and re-inserts it with a
/// fresh recency stamp). Raise the capacity rather than lowering it: the
/// working set is "every session file that already exists", which only grows.
final class OrderedBoundedCache<Value>: @unchecked Sendable {
    private struct Entry {
        let value: Value
        var stamp: Int
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var nextStamp = 0
    private let capacity: Int
    /// Number of oldest entries dropped per eviction pass.
    private let evictionBatch: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.evictionBatch = max(1, self.capacity / 4)
    }

    func value(for key: String) -> Value? {
        lock.withLock { entries[key]?.value }
    }

    func insert(_ value: Value, for key: String) {
        lock.withLock {
            if entries.count >= capacity, entries[key] == nil {
                // Keep the newest (capacity - evictionBatch) stamps; the older
                // evictionBatch entries drop.
                let cutoff = nextStamp - (capacity - evictionBatch)
                for (staleKey, entry) in entries where entry.stamp < cutoff {
                    entries.removeValue(forKey: staleKey)
                }
            }
            entries[key] = Entry(value: value, stamp: nextStamp)
            nextStamp += 1
        }
    }

    var count: Int {
        lock.withLock { entries.count }
    }
}
