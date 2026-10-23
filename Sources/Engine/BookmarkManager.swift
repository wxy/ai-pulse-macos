import Foundation
import AppKit

extension FileManager {
    /// The user's REAL home directory (e.g. `/Users/name`).
    ///
    /// Under the App Sandbox, both `NSHomeDirectory()` and
    /// `homeDirectoryForCurrentUser` are redirected to the app's container
    /// (`~/Library/Containers/<bundle-id>/Data`), which does NOT contain the
    /// user's real dot-directories like `~/.claude`. `getpwuid` returns the true
    /// home path and is unaffected by the sandbox redirection, so it is correct
    /// in both sandboxed and non-sandboxed builds.
    var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()) {
            let path = String(cString: pw.pointee.pw_dir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return homeDirectoryForCurrentUser
    }
}

/// Manages Security-Scoped Bookmarks for sandbox file access.
/// Allows the app to persist read access to user-selected directories
/// across launches, as required by the App Sandbox.
enum BookmarkManager {

    static let didChange = Notification.Name("bookmarkAccessDidChange")
    private static let accessLock = NSLock()
    private nonisolated(unsafe) static var activeResources: [String: URL] = [:]

    private static let bookmarksKey = "security_scoped_bookmarks"

    // MARK: - Environment

    /// Whether the app is running inside the macOS App Sandbox (MAS / Xcode build).
    /// Unsandboxed `make run-app` (Developer ID) reads the home directory directly.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Real `~/.claude` directory path. Uses the true home dir (not the sandbox
    /// container) so detection and bookmark checks match what the user grants.
    static var claudeDirPath: String {
        FileManager.default.realHomeDirectory
            .appendingPathComponent(".claude").path
    }

    /// Path to `~/.codex` (OpenAI Codex CLI session logs).
    static var codexDirPath: String {
        FileManager.default.realHomeDirectory
            .appendingPathComponent(".codex").path
    }

    /// Path to `~/.qwen` (Qwen Code CLI session logs).
    static var qwenDirPath: String {
        FileManager.default.realHomeDirectory
            .appendingPathComponent(".qwen").path
    }

    /// Path to the user's home directory. Granting access to `~` covers all
    /// dot-dirs below it (~/.claude, ~/.codex, ~/.qwen) via `hasBookmark`.
    static var homeDirPath: String {
        FileManager.default.realHomeDirectory.path
    }

    /// True if the user has granted home-directory access (or a sub-path that
    /// covers home). A home grant lets every log-based tool be detected.
    static var hasHomeAccess: Bool {
        hasBookmark(covering: homeDirPath)
    }

    // MARK: - Public API

    /// Present an Open Panel for the user to grant access to a directory.
    /// Returns the selected URL, or nil if cancelled.
    @MainActor
    static func requestAccess(
        message: String? = nil,
        defaultDirectory: String = FileManager.default.realHomeDirectory.path
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message ?? I18n.t("bookmark.repos_message")
        panel.prompt = I18n.t("bookmark.grant")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultDirectory)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard createAndSave(for: url) else { return nil }
        return url
    }

    /// Present an Open Panel pre-pointed at `~/.claude` so the user can grant
    /// read access to Claude Code logs. Hidden files are shown so the dot-folder
    /// is visible. Returns the selected URL, or nil if cancelled.
    @discardableResult
    @MainActor
    static func requestClaudeAccess(message: String) -> URL? {
        let home = FileManager.default.realHomeDirectory
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = I18n.t("bookmark.authorize_access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home.appendingPathComponent(".claude")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard createAndSave(for: url) else { return nil }
        return url
    }

    /// Present an Open Panel pre-pointed at `~/.codex` so the user can grant
    /// read access to OpenAI Codex CLI session logs (sandbox requirement).
    @discardableResult
    @MainActor
    static func requestCodexAccess(message: String) -> URL? {
        let home = FileManager.default.realHomeDirectory
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = I18n.t("bookmark.authorize_access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home.appendingPathComponent(".codex")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard createAndSave(for: url) else { return nil }
        return url
    }

    /// Present an Open Panel pre-pointed at `~/.qwen` so the user can grant
    /// read access to Qwen Code CLI session logs (sandbox requirement).
    @discardableResult
    @MainActor
    static func requestQwenAccess(message: String) -> URL? {
        let home = FileManager.default.realHomeDirectory
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = I18n.t("bookmark.authorize_access")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home.appendingPathComponent(".qwen")

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard createAndSave(for: url) else { return nil }
        return url
    }

    /// Present an Open Panel pre-pointed at the home directory so the user can
    /// grant access to `~` once, covering all log-based tools below it
    /// (~/.claude, ~/.codex, ~/.qwen). Legal user-selected file access — not a
    /// temporary exception — so it passes App Store review.
    @discardableResult
    @MainActor
    static func requestHomeAccess(message: String) -> URL? {
        let home = FileManager.default.realHomeDirectory
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = I18n.t("bookmark.grant_to_detect")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = home
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        guard createAndSave(for: url) else { return nil }
        return url
    }

    /// Whether any saved bookmark grants access to `path` (i.e. a bookmark whose
    /// directory is `path` itself or an ancestor of it).
    static func hasBookmark(covering path: String) -> Bool {
        savedBookmarks().keys.contains { pathIsCovered(path, by: $0) }
    }

    /// Create and persist a security-scoped bookmark for a URL.
    @discardableResult
    static func createAndSave(for url: URL, logicalURL: URL? = nil) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let bookmark = try target.bookmarkData(
                options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let scoped = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !isSandboxed || activate(scoped) else {
                throw CocoaError(.fileReadNoPermission)
            }
            _ = try FileManager.default.contentsOfDirectory(atPath: target.path)
            var bookmarks = savedBookmarks()
            let coveredPaths = bookmarks.keys.filter { DirectoryAccess.contains(RepositoryScope.canonicalPath($0), in: target.path) }
            for path in Array(bookmarks.keys) where path != target.path && RepositoryScope.canonicalPath(path) == target.path {
                bookmarks.removeValue(forKey: path)
            }
            bookmarks[target.path] = bookmark
            try saveChecked(bookmarks)
            NotificationCenter.default.post(name: didChange, object: nil)
            AppHealthMonitor.shared.clearIngestError(source: "Bookmark.create")
            for path in coveredPaths {
                let label = path == homeDirPath ? "home" : URL(fileURLWithPath: path).lastPathComponent
                AppHealthMonitor.shared.clearIngestError(source: "Bookmark.\(label)")
            }
            let targetLabel = target.path == RepositoryScope.canonicalPath(homeDirPath) ? "home" : target.lastPathComponent
            AppHealthMonitor.shared.clearIngestError(source: "Bookmark.\(targetLabel)")
            return true
        } catch {
            Logger.error("BookmarkManager: grant failed: \(error.localizedDescription)")
            DirectoryAccess.shared.record(error, at: logicalURL ?? target, includeMissing: true)
            AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Bookmark.create")
            return false
        }
    }

    /// Prompt for the current real target without replacing the configured alias.
    @MainActor
    static func requestAccess(for issue: DirectoryAccessIssue) -> Bool {
        let current = URL(fileURLWithPath: issue.logicalPath).standardizedFileURL.resolvingSymlinksInPath()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = true
        panel.prompt = I18n.t("access.authorize")
        panel.message = I18n.t("access.explanation") + "\n" + issue.logicalPath + " → " + current.path
        let isFile = (try? current.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        panel.directoryURL = isFile ? current.deletingLastPathComponent() : current
        guard panel.runModal() == .OK, let selected = panel.url else { return false }
        // Recheck after the panel: the alias may have changed while it was open.
        let latest = URL(fileURLWithPath: issue.logicalPath).resolvingSymlinksInPath().standardizedFileURL.path
        guard pathIsCovered(latest, by: selected.path) else {
            let alert = NSAlert()
            alert.messageText = I18n.t("access.wrong_folder")
            alert.informativeText = latest
            alert.runModal()
            return false
        }
        return createAndSave(for: selected, logicalURL: URL(fileURLWithPath: issue.logicalPath))
    }

    /// Resolve all persisted bookmarks and begin accessing their resources.
    /// Call this at app startup, before any file I/O to sandboxed paths.
    static func resolveAll() -> [URL] {
        // A stable, non-username-leaking label for diagnostics (the home
        // bookmark's last path component is the user's name).
        func label(for path: String) -> String {
            path == homeDirPath ? "home" : URL(fileURLWithPath: path).lastPathComponent
        }

        var resolved: [URL] = []
        var bookmarks = savedBookmarks()
        var mutated = false
        for (path, data) in bookmarks {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                AppHealthMonitor.shared.reportIngestError(
                    "saved bookmark no longer resolves; re-grant access",
                    source: "Bookmark.\(label(for: path))")
                continue
            }

            // A stale bookmark still resolves this launch but will fail the
            // next one. Refresh the stored data now so access self-heals
            // across system updates and moved directories.
            if isStale {
                if let refreshed = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil) {
                    bookmarks[path] = refreshed
                    mutated = true
                    Logger.info("BookmarkManager: refreshed stale bookmark for \(label(for: path))")
                } else {
                    AppHealthMonitor.shared.reportIngestError(
                        "stale bookmark refresh failed; re-grant access",
                        source: "Bookmark.\(label(for: path))")
                }
            }

            if activate(url) {
                resolved.append(url)
                AppHealthMonitor.shared.clearIngestError(source: "Bookmark.\(label(for: path))")
            } else {
                DirectoryAccess.shared.record(CocoaError(.fileReadNoPermission), at: URL(fileURLWithPath: path))
            }
        }
        if mutated { save(bookmarks) }
        return resolved
    }

    /// A same-resource move may still be recoverable from a saved bookmark.
    /// Restore that existing grant before asking the user for a new one.
    static func restoreAccess(to path: String) -> Bool {
        guard isSandboxed else { return false }
        let target = RepositoryScope.canonicalPath(path)
        for data in savedBookmarks().values {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  DirectoryAccess.contains(target, in: RepositoryScope.canonicalPath(url.path)),
                  activate(url) else { continue }
            return true
        }
        return false
    }

    static func isAccessAvailable(for path: String) -> Bool {
        guard isSandboxed else { return true }
        accessLock.lock(); defer { accessLock.unlock() }
        let target = RepositoryScope.canonicalPath(path)
        return activeResources.keys.contains { DirectoryAccess.contains(target, in: $0) }
    }

    /// Compare actual targets so a granted physical directory also covers its
    /// aliases. A link escaping that directory still requires a target grant.
    static func pathIsCovered(_ path: String, by directory: String) -> Bool {
        let target = RepositoryScope.canonicalPath(path)
        let root = RepositoryScope.canonicalPath(directory)
        return target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func activate(_ url: URL) -> Bool {
        accessLock.lock(); defer { accessLock.unlock() }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        if activeResources[target] != nil { return true }
        guard url.startAccessingSecurityScopedResource() else { return false }
        // Snapshot the granted target, so retargeting an alias cannot expand it.
        activeResources[target] = url
        return true
    }

    /// Stop accessing the given resolved bookmarks (or all of them when the
    /// list is empty). Call at app termination.
    static func stopAll(_ urls: [URL]) {
        accessLock.lock(); defer { accessLock.unlock() }
        if urls.isEmpty {
            for url in activeResources.values { url.stopAccessingSecurityScopedResource() }
            activeResources.removeAll()
            return
        }
        for url in urls {
            guard activeResources.removeValue(forKey: url.standardizedFileURL.resolvingSymlinksInPath().path) != nil else { continue }
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Check if any bookmarks have been granted.
    static var hasAccess: Bool {
        !savedBookmarks().isEmpty
    }

    // MARK: - Private

    private static func savedBookmarks() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let dict = try? JSONDecoder().decode([String: Data].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ bookmarks: [String: Data]) {
        do { try saveChecked(bookmarks) }
        catch { AppHealthMonitor.shared.reportIngestError(error.localizedDescription, source: "Bookmark.save") }
    }

    private static func saveChecked(_ bookmarks: [String: Data]) throws {
        let data = try JSONEncoder().encode(bookmarks)
        UserDefaults.standard.set(data, forKey: bookmarksKey)
    }
}
