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

    // MARK: - Public API

    /// Present an Open Panel for the user to grant access to a directory.
    /// Returns the selected URL, or nil if cancelled.
    @MainActor
    static func requestAccess(
        message: String? = nil,
        defaultDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message ?? I18n.t("bookmark.repos_message")
        panel.prompt = I18n.t("bookmark.grant")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultDirectory)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        createAndSave(for: url)
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

        createAndSave(for: url)
        return url
    }

    /// Whether any saved bookmark grants access to `path` (i.e. a bookmark whose
    /// directory is `path` itself or an ancestor of it).
    static func hasBookmark(covering path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return savedBookmarks().keys.contains { key in
            let k = URL(fileURLWithPath: key).standardizedFileURL.path
            return target == k || target.hasPrefix(k + "/")
        }
    }

    /// Create and persist a security-scoped bookmark for a URL.
    static func createAndSave(for url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var bookmarks = savedBookmarks()
        bookmarks[url.path] = bookmark
        save(bookmarks)
    }

    /// Resolve all persisted bookmarks and begin accessing their resources.
    /// Call this at app startup, before any file I/O to sandboxed paths.
    static func resolveAll() -> [URL] {
        var resolved: [URL] = []
        for (_, data) in savedBookmarks() {
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            if url.startAccessingSecurityScopedResource() {
                resolved.append(url)
            }
        }
        return resolved
    }

    /// Stop accessing all resolved bookmarks. Call at app termination.
    static func stopAll(_ urls: [URL]) {
        for url in urls {
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
        guard let data = try? JSONEncoder().encode(bookmarks) else { return }
        UserDefaults.standard.set(data, forKey: bookmarksKey)
    }
}
