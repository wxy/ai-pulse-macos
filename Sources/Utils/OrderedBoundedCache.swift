import Foundation

/// Bounded cache with a protected history segment and a rotating admission
/// window. A sequential scan larger than capacity cannot evict the protected
/// entries before visiting them again. Window hits promote active files into
/// the protected segment; its oldest entry moves back to the window.
final class OrderedBoundedCache<Value>: @unchecked Sendable {
    private final class Entry {
        let key: String
        var value: Value
        var isProtected = false
        weak var previous: Entry?
        var next: Entry?

        init(key: String, value: Value) {
            self.key = key
            self.value = value
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let protectedCapacity: Int
    private let windowCapacity: Int
    private var protectedCount = 0
    private var windowCount = 0
    private var protectedHead: Entry?
    private var protectedTail: Entry?
    private var windowHead: Entry?
    private var windowTail: Entry?

    init(capacity: Int) {
        let capacity = max(1, capacity)
        windowCapacity = max(1, capacity / 4)
        protectedCapacity = capacity - windowCapacity
    }

    deinit {
        // Break long chains while the dictionary still owns every entry.
        for entry in entries.values { entry.next = nil }
    }

    func value(for key: String) -> Value? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            detach(entry)
            append(entry, protected: protectedCapacity > 0)
            if protectedCount > protectedCapacity, let oldest = protectedHead {
                detach(oldest)
                append(oldest, protected: false)
            }
            trimWindow()
            return entry.value
        }
    }

    func insert(_ value: Value, for key: String) {
        lock.withLock {
            if let entry = entries[key] {
                entry.value = value
                let wasProtected = entry.isProtected
                detach(entry)
                append(entry, protected: wasProtected)
            } else {
                let entry = Entry(key: key, value: value)
                entries[key] = entry
                append(entry, protected: protectedCount < protectedCapacity)
            }
            trimWindow()
        }
    }

    private func append(_ entry: Entry, protected: Bool) {
        entry.isProtected = protected
        let tail = protected ? protectedTail : windowTail
        entry.previous = tail
        tail?.next = entry
        if protected {
            if protectedHead == nil { protectedHead = entry }
            protectedTail = entry
            protectedCount += 1
        } else {
            if windowHead == nil { windowHead = entry }
            windowTail = entry
            windowCount += 1
        }
    }

    private func detach(_ entry: Entry) {
        if let previous = entry.previous { previous.next = entry.next }
        else if entry.isProtected { protectedHead = entry.next }
        else { windowHead = entry.next }
        if let next = entry.next { next.previous = entry.previous }
        else if entry.isProtected { protectedTail = entry.previous }
        else { windowTail = entry.previous }
        entry.previous = nil
        entry.next = nil
        if entry.isProtected { protectedCount -= 1 }
        else { windowCount -= 1 }
    }

    private func trimWindow() {
        while windowCount > windowCapacity, let oldest = windowHead {
            detach(oldest)
            entries.removeValue(forKey: oldest.key)
        }
    }

    var count: Int {
        lock.withLock { entries.count }
    }
}
