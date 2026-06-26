import Foundation

struct CodeChange: Codable {
    let commitHash: String
    let ts: Int        // epoch ms
    let repoPath: String
    let added: Int
    let deleted: Int
    let isMerge: Bool
}

/// Monitors git repositories for new commits and extracts net line changes
final class GitMonitor {
    static let shared = GitMonitor()
    private var watchedRepos: Set<String> = []
    private var lastSeenCommit: [String: String] = [:] // repo -> last processed commit hash

    /// Exclusion patterns for non-code files (glob-style)
    private static let excludedSuffixes: Set<String> = [
        ".lock", "package-lock.json", "pnpm-lock.yaml", "yarn.lock",
        ".pb.go", ".generated.swift", ".generated.ts", ".graphql",
        ".min.js", ".min.css", ".map"
    ]
    private static let excludedDirs: Set<String> = [
        "node_modules", "dist", "build", ".next", "vendor", "__pycache__"
    ]

    /// Start watching a git repo for new commits
    func watch(repoPath: String) {
        guard !watchedRepos.contains(repoPath) else { return }
        watchedRepos.insert(repoPath)
        // Scan existing commits
        scanRecentCommits(repo: repoPath)
    }

    /// Poll watched repos - called periodically or after log ingestion
    func poll() {
        for repo in watchedRepos {
            scanRecentCommits(repo: repo)
        }
    }

    // MARK: - Private

    private func scanRecentCommits(repo: String) {
        let lastHash = lastSeenCommit[repo]
        // Get all commits we haven't seen yet (last 20)
        let range = lastHash.map { "\($0)..HEAD" } ?? "HEAD~20..HEAD"
        guard let output = runGit(repo: repo, args: ["log", "--format=%H %ct %P", range, "--", "."]),
              !output.isEmpty else { return }

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: " ")
            guard parts.count >= 2 else { continue }
            let hash = parts[0]
            let ts = (Int(parts[1]) ?? 0) * 1000
            let parentCount = parts.count - 2
            let isMerge = parentCount >= 2

            // Get numstat for this commit
            guard let numstat = runGit(repo: repo, args: ["show", "--numstat", "--format=", hash]),
                  !numstat.isEmpty else { continue }

            var added = 0
            var deleted = 0
            for statLine in numstat.components(separatedBy: .newlines) {
                let fields = statLine.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard fields.count >= 3, let a = Int(fields[0]), let d = Int(fields[1]) else { continue }
                let file = fields[2]
                if isExcluded(file: file) { continue }
                added += a
                deleted += d
            }

            if added > 0 || deleted > 0 {
                insertChange(CodeChange(commitHash: hash, ts: ts, repoPath: repo, added: added, deleted: deleted, isMerge: isMerge))
            }

            lastSeenCommit[repo] = hash
        }
    }

    private func isExcluded(file: String) -> Bool {
        for suffix in Self.excludedSuffixes where file.hasSuffix(suffix) { return true }
        for dir in Self.excludedDirs where file.contains("/\(dir)/") || file.hasPrefix("\(dir)/") { return true }
        return false
    }

    private func runGit(repo: String, args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo] + args
        process.currentDirectoryURL = URL(fileURLWithPath: repo)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            print("Git error for \(repo): \(error)")
            return nil
        }
    }

    private func insertChange(_ change: CodeChange) {
        Task {
            do {
                try await AppDatabase.shared.write { db in
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO code_change (commit_hash, ts, repo_path, added, deleted, is_merge)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """, arguments: [change.commitHash, change.ts, change.repoPath, change.added, change.deleted, change.isMerge])
                }
            } catch {
                print("Failed to insert code change: \(error)")
            }
        }
    }
}
