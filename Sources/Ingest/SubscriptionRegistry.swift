import Foundation
import AppKit

/// A detected subscription tool (installed IDE with a monthly plan).
struct SubscriptionTool: Identifiable {
    var id: String { name }
    let name: String
    let bundleIds: [String]
    let tiers: [SubscriptionTier]
    let installed: Bool
}

struct SubscriptionTier: Identifiable {
    var id: String { label }
    let label: String
    let fee: Double
    let currency: String
}

/// Registry of subscription-based AI coding tools that can be detected on disk.
enum SubscriptionRegistry {
    static func tool(forName name: String) -> SubscriptionTool? {
        tools.first { $0.name == name }
    }

    static func tool(forBundleId id: String) -> SubscriptionTool? {
        tools.first { $0.bundleIds.contains(id) }
    }
    /// All known subscription tools.  Displayed in settings only if `installed` is true.
    static let tools: [SubscriptionTool] = {
        let fm = FileManager.default

        func isInstalled(_ bids: [String]) -> Bool {
            for bid in bids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
                   fm.fileExists(atPath: url.path) { return true }
            }
            return false
        }

        let defs: [(name: String, bundleIds: [String], tiers: [(String, Double)])] = [
            ("Cursor",   ["com.todesktop.230313mzl4w4u92"], [
                ("Pro", 20), ("Business", 40), ("第三方 API", 0),
            ]),
            ("Windsurf", ["com.codeium.windsurf"], [
                ("Pro", 15), ("第三方 API", 0),
            ]),
            ("Trae",     ["com.trae.app"], [
                ("Pro", 10), ("第三方 API", 0),
            ]),
            // Copilot works in both VS Code stable + insiders — one subscription
            ("GitHub Copilot", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], [
                ("Pro", 10), ("Pro+", 39), ("Business", 19), ("Enterprise", 39), ("第三方 API", 0),
            ]),
            ("Augment Code", ["com.augmentcode.augmentcode"], [
                ("Pro", 30), ("Business", 60), ("第三方 API", 0),
            ]),
        ]

        return defs.map { d in
            let tiers = d.tiers.map { SubscriptionTier(label: $0.0, fee: $0.1, currency: "USD") }
            return SubscriptionTool(name: d.name, bundleIds: d.bundleIds, tiers: tiers, installed: isInstalled(d.bundleIds))
        }
    }()
}
