import Foundation

/// aider log parsing.
/// Data source: `<repo>/.aider.llm.history` in watched repos.
/// Not a CostSource itself — log entries are attributed to apiKey CostSources.
struct AiderIntegration: Detectable {
    let id = "aider"
    let displayName = "aider"
    var costSources: [CostSource] { [] }

    private nonisolated let cache: RepoScanCache

    /// `nil` (the default) resolves to `RepoScanCache.shared`. The `.shared`
    /// lookup happens in the init body rather than as a default argument so it
    /// evaluates under the init's own isolation. The init is `nonisolated` to
    /// match the other integrations' memberwise inits: `IntegrationRegistry.all`
    /// builds `AiderIntegration()` inside a `nonisolated(unsafe)` global, and
    /// the Xcode target compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// (which would make a bare custom init MainActor-isolated).
    nonisolated init(cache: RepoScanCache? = nil) {
        self.cache = cache ?? RepoScanCache.shared
    }

    func detect() -> DetectionResult {
        let dirs = UserDefaults.standard.stringArray(forKey: "repo_search_dirs")
            ?? ["~/dev", "~/projects", "~/code"]
        var count = 0
        for d in dirs {
            if let scan = cache.cachedScan(for: d) {
                count += scan.repos.filter(\.hasAiderMarkers).count
            } else {
                // No fresh scan yet — warm the cache in the background so a
                // later detect() (or the live-updating onboarding page) is right.
                Task { await cache.scan(dir: d) }
            }
        }
        return DetectionResult(
            found: count > 0,
            summary: count > 0
                ? String(format: I18n.t("detect.aider_found"), count)
                : I18n.t("detect.aider_not_found")
        )
    }
}
