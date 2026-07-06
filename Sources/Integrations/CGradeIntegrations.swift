import Foundation
import AppKit

// MARK: - Cursor (subscription)

struct CursorIntegration: Detectable {
    let id = "cursor"
    let displayName = "Cursor"

    var costSources: [CostSource] {
        let cfg = IntegrationRegistry.config(for: id)
        guard !cfg.subscriptionTier.isEmpty else { return [] }
        guard let tool = SubscriptionRegistry.tool(forName: "Cursor"),
              let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }),
              tier.fee > 0 else { return [] }
        _ = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        return [CostSource(
            id: "sub:cursor:\(tier.label.lowercased())",
            label: "Cursor \(tier.label)",
            kind: .subscription(toolId: "cursor", tierLabel: tier.label, monthlyFee: tier.fee),
            coveredModels: PricingManager.shared.modelsForTool("cursor"),
            confidence: .amortized,
            limitations: ["超量费用暂不支持"]
        )]
    }

    func detect() -> DetectionResult {
        let bundleId = "com.todesktop.230313mzl4w4u92"
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        return DetectionResult(found: installed, summary: I18n.t(installed ? "detect.app_installed" : "detect.app_not_found").replacingOccurrences(of: "%@", with: "Cursor"))
    }
}

// MARK: - GitHub Copilot (subscription)

struct CopilotIntegration: Detectable {
    let id = "copilot"
    let displayName = "GitHub Copilot"

    var costSources: [CostSource] {
        let cfg = IntegrationRegistry.config(for: id)
        guard !cfg.subscriptionTier.isEmpty else { return [] }
        guard let tool = SubscriptionRegistry.tool(forName: "GitHub Copilot"),
              let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }),
              tier.fee > 0 else { return [] }
        _ = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        return [CostSource(
            id: "sub:copilot:\(tier.label.lowercased())",
            label: "Copilot \(tier.label)",
            kind: .subscription(toolId: "copilot", tierLabel: tier.label, monthlyFee: tier.fee),
            coveredModels: PricingManager.shared.modelsForTool("copilot"),
            confidence: .amortized,
            limitations: []
        )]
    }

    func detect() -> DetectionResult {
        let bids = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        let installed = bids.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return DetectionResult(found: installed, summary: I18n.t(installed ? "detect.app_installed" : "detect.app_not_found").replacingOccurrences(of: "%@", with: "VS Code"))
    }
}

// MARK: - Windsurf (subscription)

struct WindsurfIntegration: Detectable {
    let id = "windsurf"
    let displayName = "Windsurf"

    var costSources: [CostSource] {
        let cfg = IntegrationRegistry.config(for: id)
        guard !cfg.subscriptionTier.isEmpty else { return [] }
        guard let tool = SubscriptionRegistry.tool(forName: "Windsurf"),
              let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }),
              tier.fee > 0 else { return [] }
        _ = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
        return [CostSource(
            id: "sub:windsurf:\(tier.label.lowercased())",
            label: "Windsurf \(tier.label)",
            kind: .subscription(toolId: "windsurf", tierLabel: tier.label, monthlyFee: tier.fee),
            coveredModels: PricingManager.shared.modelsForTool("windsurf"),
            confidence: .amortized,
            limitations: ["超量费用暂不支持"]
        )]
    }

    func detect() -> DetectionResult {
        let bundleId = "com.codeium.windsurf"
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        return DetectionResult(found: installed, summary: I18n.t(installed ? "detect.app_installed" : "detect.app_not_found").replacingOccurrences(of: "%@", with: "Windsurf"))
    }
}
