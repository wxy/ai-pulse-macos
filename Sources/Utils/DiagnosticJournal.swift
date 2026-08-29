import Compression
import Foundation

/// A type-safe value accepted by the diagnostic journal.
///
/// The journal serializes these cases directly so a non-finite `Double` can be
/// represented as JSON `null` instead of producing invalid JSON or losing the
/// distinction between "missing" and "impossible number".
nonisolated enum DiagnosticValue: Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case date(Date)
    case array([DiagnosticValue])
    case object([String: DiagnosticValue])
}

/// Bounded, append-only behavior journal used as a local black-box recorder.
///
/// The active segment is plain JSONL for immediate readability. When it passes
/// a byte or line threshold it is rotated to a zlib-compressed archive. The
/// archive budget is enforced after every rotation by deleting the oldest
/// files first. Mutable file state is confined to `writerQueue`.
nonisolated final class DiagnosticJournal: @unchecked Sendable {
    static let shared = DiagnosticJournal()

    private let writerQueue = DispatchQueue(
        label: "com.wxy.aipulse.diagnostic-journal",
        qos: .utility
    )
    private let directory: URL
    private let activeByteLimit: Int
    private let activeLineLimit: Int
    private let archiveByteLimit: Int

    private struct WriterState {
        var handle: FileHandle?
        var byteCount = 0
        var lineCount = 0
        let sessionID = UUID().uuidString
        var sequence = 0
    }

    private nonisolated(unsafe) var state = WriterState()

    init(
        directory: URL? = nil,
        activeByteLimit: Int = 256 * 1024,
        activeLineLimit: Int = 2_000,
        archiveByteLimit: Int = 4 * 1024 * 1024
    ) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("AIPulse", isDirectory: true)
                .appendingPathComponent("diagnostics", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("AIPulse-diagnostics", isDirectory: true)
        self.activeByteLimit = max(activeByteLimit, 1)
        self.activeLineLimit = max(activeLineLimit, 1)
        self.archiveByteLimit = max(archiveByteLimit, 1)
    }

    /// Records one behavioral boundary. This method never performs file I/O on
    /// the calling thread and never throws.
    static func log(_ name: String, _ data: [String: DiagnosticValue] = [:]) {
        shared.append(name, data)
    }

    func log(_ name: String, _ data: [String: DiagnosticValue]) {
        append(name, data)
    }

    private func append(_ name: String, _ data: [String: DiagnosticValue]) {
        writerQueue.async { [self] in
            state.sequence += 1
            let line = Self.makeLine(
                event: name,
                data: data,
                sequence: state.sequence,
                sessionID: state.sessionID
            )
            append(line: line)
        }
    }

    // MARK: - Test support

    func flushForTesting() {
        writerQueue.sync { }
    }

    var activeFileURL: URL {
        directory.appendingPathComponent("events-active.jsonl")
    }

    func archiveURLs() -> [URL] {
        writerQueue.sync {
            archiveURLsLocked()
        }
    }

    // MARK: - JSON encoding

    private static func makeLine(
        event: String,
        data: [String: DiagnosticValue],
        sequence: Int,
        sessionID: String
    ) -> String {
        let fields: [(String, String)] = [
            ("v", "1"),
            ("seq", String(sequence)),
            ("ts", quoted(ISO8601DateFormatter.string(
                from: Date(),
                timeZone: .current,
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            ))),
            ("uptime", numberString(ProcessInfo.processInfo.systemUptime)),
            ("pid", String(ProcessInfo.processInfo.processIdentifier)),
            ("session", quoted(sessionID)),
            ("app", quoted(Self.appDescription)),
            ("os", quoted(ProcessInfo.processInfo.operatingSystemVersionString)),
            ("event", quoted(event)),
            ("data", objectString(data)),
        ]
        return "{" + fields.map { "\(quoted($0.0)):\($0.1)" }.joined(separator: ",") + "}"
    }

    private static var appDescription: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "unknown"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        return "v\(version)/\(build)"
    }

    private static func objectString(_ object: [String: DiagnosticValue]) -> String {
        let fields = object
            .sorted { $0.key < $1.key }
            .map { "\(quoted($0.key)):\(valueString($0.value))" }
        return "{\(fields.joined(separator: ","))}"
    }

    private static func arrayString(_ values: [DiagnosticValue]) -> String {
        "[\(values.map(valueString).joined(separator: ","))]"
    }

    private static func valueString(_ value: DiagnosticValue) -> String {
        switch value {
        case .string(let string):
            return quoted(string)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .int(let int):
            return String(int)
        case .double(let double):
            return double.isFinite ? numberString(double) : "null"
        case .date(let date):
            return quoted(ISO8601DateFormatter.string(
                from: date,
                timeZone: .current,
                formatOptions: [.withInternetDateTime, .withFractionalSeconds]
            ))
        case .array(let array):
            return arrayString(array)
        case .object(let object):
            return objectString(object)
        }
    }

    private static func numberString(_ value: Double) -> String {
        String(format: "%.17g", value)
    }

    private static func quoted(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private static func escaped(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }

    // MARK: - File writing and rotation

    private func append(line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if state.handle != nil,
           state.byteCount > 0,
           (state.byteCount + data.count > activeByteLimit || state.lineCount + 1 > activeLineLimit) {
            rotateLocked()
        }

        if state.handle == nil {
            openLocked()
        }

        do {
            try state.handle?.seekToEnd()
            try state.handle?.write(contentsOf: data)
            state.byteCount += data.count
            state.lineCount += 1
        } catch {
            closeLocked()
            openLocked()
            _ = try? state.handle?.seekToEnd()
            _ = try? state.handle?.write(contentsOf: data)
            state.byteCount += data.count
            state.lineCount += 1
        }
    }

    private func openLocked() {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }

        let url = activeFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            rotateLocked()
        }

        FileManager.default.createFile(atPath: url.path, contents: nil)
        state.handle = try? FileHandle(forWritingTo: url)
        state.byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        state.lineCount = 0
    }

    private func rotateLocked() {
        closeLocked()
        let source = activeFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: Date())
        let baseName = "events-\(stamp)-\(UUID().uuidString).jsonl"
        let destination = directory.appendingPathComponent(baseName + ".zlib")

        if compress(source: source, destination: destination) {
            try? FileManager.default.removeItem(at: source)
        }
        enforceArchiveBudgetLocked()
    }

    private func compress(source: URL, destination: URL) -> Bool {
        guard let input = try? Data(contentsOf: source), !input.isEmpty else { return false }
        let destinationCapacity = max(input.count * 2, 1_024)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
        defer { destinationBuffer.deallocate() }

        let compressedSize = input.withUnsafeBytes { rawBuffer -> Int in
            guard let sourceBuffer = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(
                destinationBuffer,
                destinationCapacity,
                sourceBuffer,
                input.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard compressedSize > 0 else { return false }
        return (try? Data(bytes: destinationBuffer, count: compressedSize).write(to: destination)) != nil
    }

    private func archiveURLsLocked() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("events-") }
            .filter { $0.pathExtension == "zlib" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func enforceArchiveBudgetLocked() {
        var totalSize = archiveURLsLocked().reduce(0) { size, url in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return size + fileSize
        }

        // Sorted newest-first; deleting from the end removes the oldest first.
        for url in archiveURLsLocked().reversed() where totalSize > archiveByteLimit {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: url)
            totalSize -= fileSize
        }
    }

    private func closeLocked() {
        try? state.handle?.close()
        state.handle = nil
        state.byteCount = 0
        state.lineCount = 0
    }
}
