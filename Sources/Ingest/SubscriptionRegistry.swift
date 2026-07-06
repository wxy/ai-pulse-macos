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
        let appDirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications"),
        ]

        func isInstalled(_ bids: [String]) -> Bool {
            for bid in bids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid),
                   fm.fileExists(atPath: url.path) { return true }
                for dir in appDirs {
                    guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                    else { continue }
                    for app in contents where app.pathExtension == "app" {
                        if let b = Bundle(url: app)?.bundleIdentifier, b == bid { return true }
                    }
                }
            }
            return false
        }

        let defs: [(name: String, bundleIds: [String], tiers: [(String, Double)])] = [
            ("Claude Code", ["com.anthropic.claude"], [
                ("Pro", 20), ("Max 5x", 100), ("Max 20x", 200),
            ]),
            ("Cursor",   ["com.todesktop.230313mzl4w4u92"], [
                ("Pro", 20), ("Business", 40),
            ]),
            ("Windsurf", ["com.codeium.windsurf"], [
                ("Pro", 15),
            ]),
            ("Trae",     ["com.trae.app"], [
                ("Pro", 10),
            ]),
            ("GitHub Copilot", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], [
                ("Pro", 10), ("Pro+", 39), ("Business", 19), ("Enterprise", 39),
            ]),
            ("Augment Code", ["com.augmentcode.augmentcode"], [
                ("Pro", 30), ("Business", 60),
            ]),
        ]

        return defs.map { d in
            let tiers = d.tiers.map { SubscriptionTier(label: $0.0, fee: $0.1, currency: "USD") }
            return SubscriptionTool(name: d.name, bundleIds: d.bundleIds, tiers: tiers, installed: isInstalled(d.bundleIds))
        }
    }()
}
