import Foundation

/// Timestamp resolution for ingested events whose source-provided time is
/// missing or unparseable.
///
/// The 2026-09-24 code review found six parsers silently stamping such events
/// with the current wall clock: re-imported history piled onto the scan day
/// with no observable signal. The resolution chain is now
/// parsed → file mtime → wall clock, and every downgrade is counted with a
/// rate-limited diagnostic event so clock-stamping stays visible.
nonisolated enum EventTimestamp {
    /// Resolves the event timestamp in milliseconds after the source-provided
    /// value is missing or failed to parse.
    ///
    /// A non-positive `fileModifiedMs` is treated as "stat failed", not as a
    /// real epoch timestamp.
    ///
    /// - Parameters:
    ///   - parsed: the source timestamp, already converted to epoch ms, or nil.
    ///   - fileModifiedMs: the containing file's modification time in ms.
    ///   - source: parser identity used for the diagnostic counter.
    ///   - reportFallback: pass false only when the file mtime is the designed
    ///     timestamp source for this format (aider Markdown has no per-line
    ///     time at all) rather than a degradation worth counting.
    static func resolve(
        parsed: Int?,
        fileModifiedMs: Int?,
        source: String,
        reportFallback: Bool = true
    ) -> Int {
        if let parsed { return parsed }
        if let mtime = fileModifiedMs, mtime > 0 {
            if reportFallback,
               ParserTimestampFallbackCounter.shared.record(source: source, mode: .fileMtime) {
                DiagnosticJournal.log("parser_timestamp_fallback", [
                    "source": .string(source),
                    "mode": .string(ParserTimestampFallbackCounter.Mode.fileMtime.rawValue),
                ])
            }
            return mtime
        }
        if reportFallback,
           ParserTimestampFallbackCounter.shared.record(source: source, mode: .wallClock) {
            DiagnosticJournal.log("parser_timestamp_fallback", [
                "source": .string(source),
                "mode": .string(ParserTimestampFallbackCounter.Mode.wallClock.rawValue),
            ])
        }
        return Int(Date().timeIntervalSince1970 * 1000)
    }
}

/// Counts timestamp fallbacks per parser source and decides when the journal
/// should hear about them: on the first occurrence, then every 50th, so a
/// corrupted history cannot flood the bounded journal with one line per event.
///
/// `@unchecked` because the only mutable state (`counts`) is NSLock-guarded.
nonisolated final class ParserTimestampFallbackCounter: @unchecked Sendable {
    enum Mode: String {
        case fileMtime = "file_mtime"
        case wallClock = "wall_clock"
    }

    static let shared = ParserTimestampFallbackCounter()

    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    /// Records one fallback; returns true when a diagnostic should be emitted.
    func record(source: String, mode: Mode) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = "\(source)|\(mode.rawValue)"
        let next = (counts[key] ?? 0) + 1
        counts[key] = next
        return next == 1 || next % 50 == 0
    }

    func count(source: String, mode: Mode) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts["\(source)|\(mode.rawValue)"] ?? 0
    }

    func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        counts.removeAll()
    }
}
