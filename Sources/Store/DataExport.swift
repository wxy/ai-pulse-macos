import Foundation
import Darwin
import GRDB

/// Raw-unit data export: the collected tables exactly as stored — no sums
/// across units, no currency conversion, and deliberately no cost columns
/// (legacy estimated prices must not regain a surface). SQL NULL survives as
/// an empty CSV field / JSON null so "missing component" never decays into
/// zero, and JSON keeps the stored value types (counts stay numbers).
enum DataExport {
    enum Kind: Sendable { case csv, json }

    struct Section {
        let name: String
        let header: [String]
        /// Rows of raw storage values, in header order.
        let rows: [[DatabaseValue]]
    }

    // MARK: - Sections

    /// Headers are declared explicitly so an empty table still exports its
    /// column contract instead of a headerless file.
    static func usageEvents(in db: Database) throws -> Section {
        try section(in: db, name: "usage_events",
                    header: ["ts", "source", "provider_id", "model", "in_tokens", "out_tokens",
                             "cache_tokens", "cache_creation_tokens", "reported_output_tokens",
                             "reasoning_tokens", "repo_path", "session_id", "dedupe_key"],
                    sql: """
                    SELECT ts, source, provider_id, model, in_tokens, out_tokens, cache_tokens,
                           cache_creation_tokens, reported_output_tokens, reasoning_tokens,
                           repo_path, session_id, dedupe_key
                    FROM usage_event ORDER BY ts, id
                    """)
    }

    static func balanceSnapshots(in db: Database) throws -> Section {
        try section(in: db, name: "balance_snapshots",
                    header: ["ts", "provider_id", "balance", "currency"],
                    sql: "SELECT ts, provider_id, balance, currency FROM balance_snapshot ORDER BY ts, id")
    }

    static func codeChanges(in db: Database) throws -> Section {
        try section(in: db, name: "code_changes",
                    header: ["ts", "repo_path", "commit_hash", "added", "deleted", "is_merge",
                             "attributed_tool", "attribution"],
                    sql: """
                    SELECT ts, repo_path, commit_hash, added, deleted, is_merge,
                           attributed_tool, attribution
                    FROM code_change ORDER BY ts, repo_path
                    """)
    }

    static func gitCommits(in db: Database) throws -> Section {
        try section(in: db, name: "git_commits",
                    header: ["ts", "repo_path", "commit_hash", "parent_count", "author_email", "attributed_tool"],
                    sql: """
                    SELECT ts, repo_path, commit_hash, parent_count, author_email, attributed_tool
                    FROM git_commit ORDER BY ts, repo_path
                    """)
    }

    private static func section(in db: Database, name: String, header: [String], sql: String) throws -> Section {
        let rows = try Row.fetchAll(db, sql: sql)
        return Section(name: name, header: header,
                       rows: rows.map { row in header.map { row[$0] as DatabaseValue } })
    }

    // MARK: - Rendering

    static func csv(_ section: Section) -> String {
        var lines = [section.header.map(csvTextCell).joined(separator: ",")]
        for row in section.rows {
            lines.append(row.map(csvCell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvTextCell(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    private static func csvCell(_ value: DatabaseValue) -> String {
        let text: String
        switch value.storage {
        case .null: return ""
        case .int64(let int): text = String(int)
        case .double(let double): text = String(double)
        case .string(let string): text = string
        case .blob(let data): text = data.base64EncodedString()
        }
        return csvTextCell(text)
    }

    static func jsonPayload(sections: [Section], exportedAt: Date) throws -> Data {
        var payload: [String: Any] = [
            "format": "aipulse-export-v1",
            "exported_at": ISO8601DateFormatter().string(from: exportedAt),
        ]
        for section in sections {
            payload[section.name] = section.rows.map { row in
                var object: [String: Any] = [:]
                for (index, column) in section.header.enumerated() where index < row.count {
                    object[column] = jsonValue(row[index])
                }
                return object
            }
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: return NSNull()
        case .int64(let int): return int
        case .double(let double): return double
        case .string(let string): return string
        case .blob(let data): return data.base64EncodedString()
        }
    }

    /// Reserves a fresh directory atomically, then removes it if any file
    /// fails to write. A second export in the same second cannot replace the
    /// first export's files, including when two app instances export together.
    static func write(sections: [Section], kind: Kind, exportsDirectory: URL, exportedAt: Date) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: exportedAt)
        var reserved: URL?
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : "-\(index)"
            let candidate = exportsDirectory.appendingPathComponent("export-\(stamp)\(suffix)", isDirectory: true)
            if mkdir(candidate.path, 0o700) == 0 {
                reserved = candidate
                break
            }
            if errno != EEXIST {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        guard let directory = reserved else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))
        }
        var completed = false
        defer {
            if !completed { try? manager.removeItem(at: directory) }
        }
        switch kind {
        case .csv:
            for section in sections {
                let file = directory.appendingPathComponent("\(section.name).csv")
                try csv(section).write(to: file, atomically: true, encoding: .utf8)
            }
        case .json:
            let file = directory.appendingPathComponent("aipulse-export-\(stamp).json")
            try jsonPayload(sections: sections, exportedAt: exportedAt).write(to: file, options: .atomic)
        }
        completed = true
        return directory
    }
}
