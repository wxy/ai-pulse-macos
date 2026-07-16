import Foundation
import OSLog

/// Unified logger replacing scattered `print()` and `diagLog()` calls.
///
/// Four levels with build-dependent behaviour:
///
/// | Level   | Debug build              | Release build        |
/// |---------|--------------------------|----------------------|
/// | debug   | File + console           | Compiled out (no-op) |
/// | info    | File + console           | File only            |
/// | warning | File + console           | File only            |
/// | error   | File + console           | File + OSLog         |
///
/// Log files live under `~/Library/Logs/AIPulse/`.  Each file rolls at 1 MiB,
/// keeping one `.old` backup.
enum Logger {

    // MARK: - Public API

    /// Absolute URL of the active log file so users can locate and share it.
    static var logFileURL: URL {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AIPulse")
        return logDir.appendingPathComponent(logFileName)
    }

    /// Detailed diagnostic messages.  Entirely compiled out in Release builds.
    static func debug(_ msg: String,
                      file: String = #fileID,
                      function: String = #function) {
        #if DEBUG
        emit(level: .debug, msg, file: file, function: function)
        #endif
    }

    /// Key lifecycle events (startup, shutdown, data-change notifications).
    static func info(_ msg: String,
                     file: String = #fileID,
                     function: String = #function) {
        emit(level: .info, msg, file: file, function: function)
    }

    /// Recoverable anomalies (missing optional resource, empty API response).
    static func warning(_ msg: String,
                        file: String = #fileID,
                        function: String = #function) {
        emit(level: .warning, msg, file: file, function: function)
    }

    /// Errors that need attention (DB write failure, API call failure).
    static func error(_ msg: String,
                      file: String = #fileID,
                      function: String = #function) {
        emit(level: .error, msg, file: file, function: function)
    }

    // MARK: - Internals

    private enum Level: String {
        case debug   = "D"
        case info    = "I"
        case warning = "W"
        case error   = "E"
    }

    private static let queue = DispatchQueue(
        label: "com.wxy.aipulse.logger", qos: .utility)
    private static let maxFileSize = 1_048_576  // 1 MiB

    #if DEBUG
    private static let logFileName = "aipulse-debug.log"
    #else
    private static let logFileName = "aipulse.log"
    #endif

    private static let oslog = OSLog(
        subsystem: "com.wxy.aipulse", category: "general")

    private static func emit(level: Level,
                             _ msg: String,
                             file: String,
                             function: String) {
        let line = format(level: level, msg, file: file, function: function)

        // Console (NSLog is always safe from any thread)
        NSLog("%@", line)

        // OSLog for error level in Release
        #if !DEBUG
        if level == .error {
            os_log(.error, log: oslog, "%{public}@", line)
        }
        #endif

        // File
        queue.async {
            Task { @MainActor in
                writeToFile(line)
            }
        }
    }

    private static func format(level: Level,
                               _ msg: String,
                               file: String,
                               function: String) -> String {
        let ts = ISO8601DateFormatter.string(
            from: Date(),
            timeZone: .current,
            formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        // Strip module path down to filename for readability
        let shortFile = file.split(separator: "/").last.map(String.init) ?? file
        return "[\(ts)] \(level.rawValue) \(shortFile):\(function) \(msg)"
    }

    // MARK: - File I/O

    private static nonisolated(unsafe) var fileHandle: FileHandle?
    private static nonisolated(unsafe) var currentFileSize: Int = 0

    private static func writeToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        if fileHandle == nil {
            openLogFile()
        }

        do {
            try fileHandle?.seekToEnd()
            try fileHandle?.write(contentsOf: data)
            currentFileSize += data.count

            if currentFileSize >= maxFileSize {
                rollLogFile()
            }
        } catch {
            // If writing fails (disk full, permissions), try to reopen
            fileHandle = nil
            currentFileSize = 0
            openLogFile()
            _ = try? fileHandle?.seekToEnd()
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private static func openLogFile() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AIPulse")
        try? FileManager.default.createDirectory(
            at: logDir, withIntermediateDirectories: true)

        let url = logDir.appendingPathComponent(logFileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        currentFileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func rollLogFile() {
        fileHandle?.closeFile()
        fileHandle = nil
        currentFileSize = 0

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AIPulse")
        let url = logDir.appendingPathComponent(logFileName)
        let backup = logDir.appendingPathComponent(logFileName + ".old")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)

        openLogFile()
    }
}
