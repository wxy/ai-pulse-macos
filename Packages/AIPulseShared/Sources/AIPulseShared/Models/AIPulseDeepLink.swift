import Foundation

public enum AIPulseDeepLink {
    public static let scheme = "aipulse"
    public static let debugScheme = "aipulse-debug"
    /// Ranges a deep link may request; mirrors the dashboard tab keys.
    public static let validRanges: Set<String> = ["today", "week", "30d"]

    public static var dashboardURL: URL {
        dashboardURL(for: Bundle.main.bundleIdentifier)
    }

    public static func dashboardURL(for bundleIdentifier: String?) -> URL {
        dashboardURL(for: bundleIdentifier, range: nil)
    }

    /// - Parameter range: optional dashboard tab ("today" / "week" / "30d").
    ///   An unknown range is dropped, so the link still opens the dashboard on
    ///   the app's own default instead of failing to route at all.
    public static func dashboardURL(for bundleIdentifier: String?, range: String?) -> URL {
        let selectedScheme = bundleIdentifier?.contains(".debug") == true ? debugScheme : scheme
        var components = URLComponents()
        components.scheme = selectedScheme
        components.host = "dashboard"
        if let range, validRanges.contains(range) {
            components.queryItems = [URLQueryItem(name: "range", value: range)]
        }
        return components.url!
    }

    public struct DashboardLink: Equatable, Sendable {
        /// nil when the link carries no (valid) range: open the app default.
        public let range: String?
    }

    public static func parse(_ url: URL) -> DashboardLink? {
        guard [scheme, debugScheme].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "dashboard" else { return nil }
        let range = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "range" }?.value
        guard let range, validRanges.contains(range) else { return DashboardLink(range: nil) }
        return DashboardLink(range: range)
    }

    public static func opensDashboard(_ url: URL) -> Bool {
        parse(url) != nil
    }
}
