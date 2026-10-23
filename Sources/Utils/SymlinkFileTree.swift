import Foundation

/// Traverse real targets at every level, including a linked starting directory.
/// Canonical URLs give aliases one file/cursor identity. Breadth-first order
/// visits the shallowest alias first, preserving depth limits with deduplication.
nonisolated enum SymlinkFileTree {
    /// With matchingFiles, yield only files that match their logical source
    /// path. directoryContext distinguishes source layouts (e.g. chats vs an
    /// unrelated alias) using a finite key, while cycles remain bounded.
    static func enumerator(
        at directory: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions = [],
        deadline: Date? = nil,
        now: @escaping () -> Date = Date.init,
        maximumDepth: Int = .max,
        skippingDirectoryNames: Set<String> = [],
        matchingFiles: ((URL) -> Bool)? = nil,
        directoryContext: @escaping (URL) -> String = { _ in "" }
    ) -> Enumerator? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return Enumerator(root: root, keys: keys ?? [], options: options,
                          deadline: deadline, now: now, maximumDepth: maximumDepth, skippedNames: skippingDirectoryNames,
                          logicalRoot: directory, matchingFiles: matchingFiles, directoryContext: directoryContext)
    }

    final class Enumerator: NSEnumerator {
        private let keys: [URLResourceKey]
        private let options: FileManager.DirectoryEnumerationOptions
        private let deadline: Date?
        private let now: () -> Date
        private let maximumDepth: Int
        private let skippedNames: Set<String>
        private let matchingFiles: ((URL) -> Bool)?
        private let directoryContext: (URL) -> String
        private var directories: [(url: URL, logical: URL, depth: Int)]
        private var nextDirectory = 0
        private var current: FileManager.DirectoryEnumerator?
        private var currentDepth = 0
        private var currentLogicalRoot: URL
        private var pendingDirectory: (url: URL, logical: URL, depth: Int)?
        private var visitedDirectories: Set<String>
        private var visitedFiles: Set<String> = []
        private(set) var level = 0
        private(set) var logicalURL: URL?
        private(set) var truncated = false

        init(root: URL, keys: [URLResourceKey], options: FileManager.DirectoryEnumerationOptions,
             deadline: Date?, now: @escaping () -> Date, maximumDepth: Int, skippedNames: Set<String>, logicalRoot: URL,
             matchingFiles: ((URL) -> Bool)?, directoryContext: @escaping (URL) -> String) {
            self.keys = Array(Set(keys + [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]))
            self.options = options
            self.deadline = deadline
            self.now = now
            self.maximumDepth = maximumDepth
            self.skippedNames = skippedNames
            self.matchingFiles = matchingFiles
            self.directoryContext = directoryContext
            currentLogicalRoot = logicalRoot
            directories = [(root, logicalRoot, 0)]
            visitedDirectories = [root.path + "\0" + directoryContext(logicalRoot)]
            super.init()
        }

        func skipDescendants() { pendingDirectory = nil }

        override func nextObject() -> Any? {
            if let pendingDirectory { directories.append(pendingDirectory) }
            pendingDirectory = nil
            while true {
                // Discarded aliases never reach the caller's loop. Account for
                // them here as well so one nextObject cannot bypass the budget.
                if truncated || deadline.map({ now() >= $0 }) == true {
                    truncated = true
                    current = nil
                    pendingDirectory = nil
                    return nil
                }
                if let entry = current?.nextObject() as? URL {
                    // Foundation can return /private/var children for a /var
                    // root, even for non-link entries. Normalize every URL.
                    let url = entry.standardizedFileURL.resolvingSymlinksInPath()
                    let logical = currentLogicalRoot.appendingPathComponent(entry.lastPathComponent)
                    guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                    level = currentDepth + 1
                    if values.isDirectory == true {
                        // Apply exclusions to both the alias and its target.
                        guard !skippedNames.contains(entry.lastPathComponent),
                              !skippedNames.contains(url.lastPathComponent),
                              visitedDirectories.insert(url.path + "\0" + directoryContext(logical)).inserted else { continue }
                        if level < maximumDepth,
                           !(options.contains(.skipsPackageDescendants) && values.isPackage == true) {
                            if matchingFiles != nil { directories.append((url, logical, level)) }
                            else { pendingDirectory = (url, logical, level) }
                        }
                        if matchingFiles != nil { continue }
                        logicalURL = logical
                        return url
                    }
                    // Match the source's logical layout before deduplicating.
                    // A chats link may point at a differently named directory.
                    guard values.isRegularFile == true,
                          matchingFiles?(logical) != false,
                          visitedFiles.insert(url.path).inserted else { continue }
                    logicalURL = logical
                    return url
                }
                guard nextDirectory < directories.count else { return nil }
                let directory = directories[nextDirectory]
                nextDirectory += 1
                currentDepth = directory.depth
                currentLogicalRoot = directory.logical
                current = FileManager.default.enumerator(
                    at: directory.url, includingPropertiesForKeys: keys,
                    options: options.union(.skipsSubdirectoryDescendants))
            }
        }
    }
}
