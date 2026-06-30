import Foundation
import AppKit

/// Manages Security-Scoped Bookmarks for sandbox file access.
/// Allows the app to persist read access to user-selected directories
/// across launches, as required by the App Sandbox.
enum BookmarkManager {

    private static let bookmarksKey = "security_scoped_bookmarks"

    // MARK: - Public API

    /// Present an Open Panel for the user to grant access to a directory.
    /// Returns the selected URL, or nil if cancelled.
    static func requestAccess(
        message: String = "AI Pulse 需要访问此目录以读取 AI 日志和代码仓库",
        defaultDirectory: String = NSHomeDirectory()
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = "授权访问"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultDirectory)

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        createAndSave(for: url)
        return url
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
