import Foundation

/// A failed read is different from a successful empty scan. Keep the logical
/// entry for rescans; a security grant always belongs to the resolved resource.
nonisolated struct DirectoryAccessIssue: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case permission, unavailable, readFailure }
    let logicalPath: String
    let targetPath: String
    let kind: Kind
    let detail: String
    var id: String { logicalPath }
    var message: String {
        I18n.t(kind == .permission ? "access.required" : kind == .unavailable ? "access.unavailable" : "access.failed") + ": " + targetPath
    }
}

nonisolated final class DirectoryAccess: @unchecked Sendable {
    static let shared = DirectoryAccess()
    static let didChange = Notification.Name("DirectoryAccessDidChange")
    private let lock = NSLock()
    private var pending: [String: DirectoryAccessIssue] = [:]

    var issues: [DirectoryAccessIssue] {
        lock.withLock { pending.values.sorted { $0.logicalPath < $1.logicalPath } }
    }

    func issues(under path: String) -> [DirectoryAccessIssue] {
        let logical = URL(fileURLWithPath: path).standardizedFileURL.path
        let target = RepositoryScope.canonicalPath(path)
        return issues.filter {
            Self.contains($0.logicalPath, in: logical) || Self.contains($0.targetPath, in: target)
        }
    }

    static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    func completeScan(at url: URL, retaining failures: Set<String> = []) {
        let logical = url.standardizedFileURL.path
        // Clear by the logical entry, never by the old target after retargeting.
        let removed = lock.withLock { () -> [String] in
            let keys = pending.keys.filter { Self.contains($0, in: logical) && !failures.contains($0) }
            for key in keys { pending.removeValue(forKey: key) }
            return keys
        }
        for key in removed { AppHealthMonitor.shared.clearIngestError(source: "Access.\(key)") }
        if !removed.isEmpty { notify() }
    }

    func clear(at url: URL) {
        let key = url.standardizedFileURL.path
        let removed = lock.withLock { pending.removeValue(forKey: key) != nil }
        guard removed else { return }
        AppHealthMonitor.shared.clearIngestError(source: "Access.\(key)")
        notify()
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && [1, 13].contains(ns.code) { return true }
        return (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { isPermissionError($0) } ?? false
    }

    static func read<T>(at url: URL, _ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch {
            guard isPermissionError(error), BookmarkManager.restoreAccess(to: url.path) else { throw error }
            return try operation()
        }
    }

    @discardableResult
    func record(_ error: Error, at logicalURL: URL, includeMissing: Bool = false) -> DirectoryAccessIssue? {
        let ns = error as NSError
        let denied = Self.isPermissionError(error)
        let missing = (ns.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code))
            || (ns.domain == NSPOSIXErrorDomain && ns.code == 2)
        if missing && !includeMissing { return nil } // absent optional sources are normal
        let logical = logicalURL.standardizedFileURL
        let issue = DirectoryAccessIssue(logicalPath: logical.path,
            targetPath: logical.resolvingSymlinksInPath().standardizedFileURL.path,
            kind: denied ? .permission : missing ? .unavailable : .readFailure,
            detail: error.localizedDescription)
        let changed = lock.withLock { () -> Bool in
            guard pending[issue.id] != issue else { return false }
            pending[issue.id] = issue
            return true
        }
        if changed {
            Logger.warning("Directory read failed: \(issue.logicalPath) -> \(issue.targetPath): \(issue.detail)")
            AppHealthMonitor.shared.reportIngestError(issue.message, source: "Access.\(issue.id)")
            notify()
        }
        return issue
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}
