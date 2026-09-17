/// Main-thread ownership of asynchronous menu refreshes. Only the newest
/// request may publish UI state after suspension.
@MainActor
final class RefreshGeneration {
    private var generation: UInt64 = 0
    func begin() -> UInt64 {
        generation &+= 1
        return generation
    }
    func isCurrent(_ request: UInt64) -> Bool { request == generation }
}
