import Foundation

// MARK: - Data grade

/// What level of cost data this integration can produce.
/// Maps to COST_ATTRIBUTION L1/L2/L3.
enum DataGrade: String {
    case A = "A"  // full CPL: token + model + cwd → cost + repo + netLines
    case B = "B"  // spend only: balance/usage API → dollar amount, no repo
    case C = "C"  // subscription: flat monthly fee, no per-call tracking
}

// MARK: - Detection

/// Result of a `detect()` call — what did we find on this machine?
struct DetectionResult {
    let found: Bool
    let summary: String   // "~/.claude/projects found, 12 sessions"
}

// MARK: - Protocols

/// Every tool / provider can be detected (zero-permission, read-only).
protocol Detectable {
    var id: String { get }
    var displayName: String { get }
    var grade: DataGrade { get }
    func detect() -> DetectionResult
}

/// A-grade (log watcher) and B-grade (API poller) can be start/stopped.
/// C-grade integrations do NOT implement this (static config only).
protocol Collectable {
    func start()
    func stop()
}

// MARK: - Integration config

/// Per-integration settings persisted to UserDefaults.
struct IntegrationConfig: Codable {
    var enabled: Bool = false
    var apiKey: String = ""
    var subscriptionTier: String = ""  // C-grade
}
