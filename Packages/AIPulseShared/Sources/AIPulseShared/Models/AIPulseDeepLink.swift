import Foundation

public enum AIPulseDeepLink {
    public static let scheme = "aipulse"
    public static let debugScheme = "aipulse-debug"
    public static var dashboardURL: URL {
        dashboardURL(for: Bundle.main.bundleIdentifier)
    }

    public static func dashboardURL(for bundleIdentifier: String?) -> URL {
        let selectedScheme = bundleIdentifier?.contains(".debug") == true ? debugScheme : scheme
        return URL(string: "\(selectedScheme)://dashboard")!
    }

    public static func opensDashboard(_ url: URL) -> Bool {
        [scheme, debugScheme].contains(url.scheme?.lowercased() ?? "")
            && url.host?.lowercased() == "dashboard"
    }
}
