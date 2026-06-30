import Foundation
import AppKit

/// Detects which editor is currently editing which Git repository
/// by reading the editor's workspace state (storage.json).
enum EditorDetector {

    struct Mapping {
        let editorName: String          // "VSCode"
        let bundleId: String            // "com.microsoft.VSCode"
        let repoPath: String            // canonical git toplevel path
        let toolName: String            // "GitHub Copilot" (matches SubscriptionRegistry)
        let dailySubscriptionCost: Double
        let confidence: Confidence
    }

    enum Confidence {
        case certain   // storage.json → git rev-parse confirmed
    }

    // MARK: - Editor definitions

    private struct EditorDef {
        let name: String
        let bundleId: String
        let appSupportDir: String       // e.g. "Code"
    }

    /// All known editors. Only those whose process is running are queried.
    private static let editors: [EditorDef] = [
        EditorDef(name: "VSCode", bundleId: "com.microsoft.VSCode", appSupportDir: "Code"),
        EditorDef(name: "VSCode Insiders", bundleId: "com.microsoft.VSCodeInsiders", appSupportDir: "Code - Insiders"),
        EditorDef(name: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92", appSupportDir: "Cursor"),
        EditorDef(name: "Windsurf", bundleId: "com.codeium.windsurf", appSupportDir: "Windsurf"),
    ]

    // MARK: - Public API

    /// Run full detection. Returns all mappings (certain + possible).
    static func detect() -> [Mapping] {
        let runningIds = Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })

        var results: [Mapping] = []
        for editor in editors where runningIds.contains(editor.bundleId) {
            results.append(contentsOf: detectEditor(editor))
        }
        return results
    }

    /// Convenience: only .certain mappings suitable for CPL attribution.
    static func certainMappings() -> [Mapping] {
        detect().filter { $0.confidence == .certain }
    }

    // MARK: - Per-editor detection

    private static func detectEditor(_ editor: EditorDef) -> [Mapping] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storagePath = home
            .appendingPathComponent("Library/Application Support/\(editor.appSupportDir)/User/globalStorage/storage.json")
            .path

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: storagePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windowsState = json["windowsState"] as? [String: Any]
        else { return [] }

        // Collect all opened windows (not just lastActiveWindow)
        var windowDescriptors: [[String: Any]] = []
        if let opened = windowsState["openedWindows"] as? [[String: Any]] {
            windowDescriptors = opened
        }

        // Extract folder URI from each window
        var folderURIs: [String] = []
        for win in windowDescriptors {
            if let folder = win["folder"] as? String {
                folderURIs.append(folder)
            } else if let wsId = win["workspaceIdentifier"] as? [String: Any],
                      let configPath = wsId["configURIPath"] as? String {
                folderURIs.append(configPath)
            }
        }

        // Resolve subscription tool — map editor bundle ID → C-grade integration ID
        // (tool name from SubscriptionRegistry ≠ integration id from IntegrationRegistry)
        let bundleIdToIntegId: [String: String] = [
            "com.microsoft.VSCode": "copilot",
            "com.microsoft.VSCodeInsiders": "copilot",
            "com.todesktop.230313mzl4w4u92": "cursor",
            "com.codeium.windsurf": "windsurf",
        ]
        let toolName: String
        let dailyCost: Double
        if let integId = bundleIdToIntegId[editor.bundleId],
           let tool = SubscriptionRegistry.tool(forBundleId: editor.bundleId) {
            toolName = tool.name
            let cfg = IntegrationRegistry.config(for: integId)
            if !cfg.subscriptionTier.isEmpty,
               let tier = tool.tiers.first(where: { $0.label == cfg.subscriptionTier }) {
                let days = Double(Calendar.current.range(of: .day, in: .month, for: Date())?.count ?? 30)
                dailyCost = tier.fee / days
            } else {
                dailyCost = 0
            }
        } else {
            toolName = editor.name
            dailyCost = 0
        }

        // Build mappings for each unique repo
        var seenRepos = Set<String>()
        var results: [Mapping] = []
        for uri in folderURIs {
            let rawPath = uri.hasPrefix("file://") ? String(uri.dropFirst(7)) : uri
            let workspacePath = rawPath.removingPercentEncoding ?? rawPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDir), isDir.boolValue
            else { continue }

            if let repoPath = gitToplevel(at: workspacePath) {
                if seenRepos.insert(repoPath).inserted {
                    results.append(Mapping(
                        editorName: editor.name, bundleId: editor.bundleId,
                        repoPath: repoPath, toolName: toolName,
                        dailySubscriptionCost: dailyCost,
                        confidence: .certain
                    ))
                }
            }
        }
        return results
    }

    // MARK: - Git helpers

    /// Find the git repository root containing the given path.
    /// Uses libgit2-backed GitRepo (sandbox-compatible, no Process fork).
    private static func gitToplevel(at path: String) -> String? {
        GitRepo.findRoot(containing: path)
    }
}
