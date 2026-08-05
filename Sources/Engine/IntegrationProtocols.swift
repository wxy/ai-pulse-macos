import Foundation

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when new data has been ingested (logs, commits, or balance snapshots).
    /// UI consumers (MenuBar, Dashboard, Dock) should refresh in response.
    static let dataDidChange = Notification.Name("AIPulseDataDidChange")

    /// Posted to request the open Dashboard to switch to a specific TimeRange tab.
    /// userInfo contains "timeRange": TimeRange value.
    static let dashboardSwitchTab = Notification.Name("AIPulseDashboardSwitchTab")

    /// Posted whenever ApiPoller writes a fresh balance or error into its cache.
    /// userInfo contains "providerId": String.
    static let apiBalanceDidUpdate = Notification.Name("AIPulseApiBalanceDidUpdate")

    /// Posted to request an open Settings window to switch to a specific tab.
    /// userInfo contains "tab": String (a SettingsView sidebar tab tag).
    static let settingsSwitchTab = Notification.Name("AIPulseSettingsSwitchTab")
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

    /// The CostSources this integration can produce.
    /// Returns empty array if this integration is not a billing source
    /// (e.g. Aider — its log entries are attributed to apiKey CostSources).
    var costSources: [CostSource] { get }

    func detect() -> DetectionResult
}

/// Integrations that can be started/stopped (log watchers, API pollers).
protocol Collectable {
    func start()
    func stop()
}

// MARK: - Integration config

/// Per-integration settings persisted to UserDefaults.
struct IntegrationConfig: Codable {
    var enabled: Bool = false
    var apiKey: String = ""
    var subscriptionTier: String = ""
}
