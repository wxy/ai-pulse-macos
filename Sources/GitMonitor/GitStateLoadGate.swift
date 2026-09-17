/// Shares an in-flight initialization, but caches only successful loads.
/// A database-not-ready failure must remain retryable on the next poll.
actor GitStateLoadGate {
    private var loaded = false
    private var inFlight: Task<Bool, Never>?

    func ensureLoaded(_ load: @escaping @Sendable () async -> Bool) async -> Bool {
        if loaded { return true }
        if let inFlight { return await inFlight.value }
        let task = Task { await load() }
        inFlight = task
        let success = await task.value
        loaded = success
        inFlight = nil
        return success
    }
}
