import Foundation

/// Half-open millisecond bounds include observations at `now`, never later.
/// Calendar slots may extend beyond now; their query bounds must not.
enum ObservationBounds {
    static func upperExclusive(now: Date, periodEnd: Date) -> Int64 {
        min(Int64(floor(now.timeIntervalSince1970 * 1_000)) + 1,
            Int64(periodEnd.timeIntervalSince1970 * 1_000))
    }
}
