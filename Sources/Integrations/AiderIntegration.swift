import Foundation

/// aider log parsing.
/// Data source: `<repo>/.aider.llm.history` in watched repos.
/// Not a CostSource itself — log entries are attributed to apiKey CostSources.
struct AiderIntegration: Detectable {
    let id = "aider"
    let displayName = "aider"
    var costSources: [CostSource] { [] }

    private let cache: RepoScanCache

    init(cache: RepoScanCache = .shared) {
        self.cache = cache
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
