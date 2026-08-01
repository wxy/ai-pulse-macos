import Foundation

/// Stable, cross-process FNV-1a 64-bit hash of a string.
/// Swift's String.hash is seeded per process, so the same line re-read
/// after a relaunch produces a different value — breaking DB dedupe keys.
/// FNV-1a is deterministic and collision-resistant enough for log-line keys.
func stableHash(_ s: String) -> UInt64 {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3
    }
    return hash
}
