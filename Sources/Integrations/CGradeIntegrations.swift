import Foundation
import AppKit

// MARK: - Cursor (C)

struct CursorIntegration: Detectable {
    let id = "cursor"
    let displayName = "Cursor"
    let grade: DataGrade = .C

    func detect() -> DetectionResult {
        let bundleId = "com.todesktop.230313mzl4w4u92"
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        return DetectionResult(found: installed, summary: installed ? "Cursor.app installed" : "Cursor.app not found")
    }
}

// MARK: - GitHub Copilot (C)

struct CopilotIntegration: Detectable {
    let id = "copilot"
    let displayName = "GitHub Copilot"
    let grade: DataGrade = .C

    func detect() -> DetectionResult {
        let bids = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        let installed = bids.contains { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
        return DetectionResult(found: installed, summary: installed ? "VS Code installed" : "VS Code not found")
    }
}

// MARK: - Windsurf (C)

struct WindsurfIntegration: Detectable {
    let id = "windsurf"
    let displayName = "Windsurf"
    let grade: DataGrade = .C

    func detect() -> DetectionResult {
        let bundleId = "com.codeium.windsurf"
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
        return DetectionResult(found: installed, summary: installed ? "Windsurf.app installed" : "Windsurf.app not found")
    }
}
