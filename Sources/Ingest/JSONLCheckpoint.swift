import Foundation

/// Commit bounded batches before returning a durable complete-line position.
/// On any failure the caller retains its old cursor; replay is deduplicated.
enum JSONLCheckpoint {
    enum Failure: Error { case shortRead, invalidLength, persistenceFailed }

    static func read<Event>(at url: URL, from start: UInt64, fileSize: UInt64,
                            parse: (String) -> Event?, persist: ([Event]) throws -> Void) throws -> UInt64 {
        guard start <= fileSize, fileSize - start <= UInt64(Int.max) else { throw Failure.invalidLength }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        var splitter = LineSplitter()
        var events: [Event] = []
        var readCount = 0
        let expected = Int(fileSize - start)
        while readCount < expected {
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: min(1 << 20, expected - readCount)), !chunk.isEmpty else {
                    throw Failure.shortRead
                }
                readCount += chunk.count
                var writeError: Error?
                splitter.append(chunk) { line in
                    guard writeError == nil, !line.isEmpty, let event = parse(line) else { return }
                    events.append(event)
                    if events.count >= 512 {
                        do {
                            try persist(events)
                            events.removeAll(keepingCapacity: true)
                        } catch { writeError = error }
                    }
                }
                if let writeError { throw writeError }
            }
        }
        if !events.isEmpty { try persist(events) }
        // Never persist a cursor past an incomplete (possibly split UTF-8) line.
        return start + UInt64(readCount - splitter.pendingBytes.count)
    }
}
