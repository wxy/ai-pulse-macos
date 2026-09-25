import Foundation

public struct MacWidgetLocalPayload: Codable, Sendable {
    public static let currentFormatVersion = 1
    public static let producerFreshnessInterval =
        CurrentPulseEnvelope.publisherInterval + CurrentPulseEnvelope.widgetRefreshInterval

    public let formatVersion: Int
    public let writtenAt: Date
    public let todaySnapshot: DashboardSnapshot?
    public let historySnapshot: DashboardSnapshot?
    public let pulseEnvelope: CurrentPulseEnvelope?

    public init(
        writtenAt: Date,
        todaySnapshot: DashboardSnapshot?,
        historySnapshot: DashboardSnapshot?,
        pulseEnvelope: CurrentPulseEnvelope?
    ) {
        formatVersion = Self.currentFormatVersion
        self.writtenAt = writtenAt
        self.todaySnapshot = todaySnapshot?.sanitized()
        self.historySnapshot = historySnapshot?.sanitized()
        self.pulseEnvelope = pulseEnvelope
    }

    public func isProducerFresh(asOf now: Date = Date()) -> Bool {
        Self.isProducerFresh(writtenAt: writtenAt, asOf: now)
    }

    public static func isProducerFresh(writtenAt: Date, asOf now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(writtenAt)
        return age.isFinite && age >= -60 && age <= Self.producerFreshnessInterval
    }
}

public enum MacWidgetLocalStore {
    public static let appGroupIdentifier = "group.com.wxy.aipulse"
    public static let fileName = "mac_widget_snapshot_v1.json"
    public static let defaultsKey = "mac_widget_snapshot_v1"

    public enum StoreError: Error {
        case appGroupUnavailable
        case incompatibleFormat
    }

    public static func load(fileManager: FileManager = .default) throws -> MacWidgetLocalPayload? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw StoreError.appGroupUnavailable
        }
        let fileURL = container.appendingPathComponent(fileName)
        let defaults = UserDefaults(suiteName: appGroupIdentifier)

        var candidates: [MacWidgetLocalPayload] = []
        var lastError: (any Error)?
        if let defaults {
            do {
                if let payload = try load(from: defaults) { candidates.append(payload) }
            } catch {
                lastError = error
            }
        }
        do {
            if let payload = try load(from: fileURL) { candidates.append(payload) }
        } catch {
            lastError = error
        }

        if let newest = candidates.max(by: { $0.writtenAt < $1.writtenAt }) {
            return newest
        }
        if let lastError { throw lastError }
        return nil
    }

    public static func load(from url: URL) throws -> MacWidgetLocalPayload? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    public static func load(from userDefaults: UserDefaults) throws -> MacWidgetLocalPayload? {
        guard let data = userDefaults.data(forKey: defaultsKey) else { return nil }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> MacWidgetLocalPayload {
        let payload = try JSONDecoder().decode(MacWidgetLocalPayload.self, from: data)
        guard payload.formatVersion == MacWidgetLocalPayload.currentFormatVersion else {
            throw StoreError.incompatibleFormat
        }
        return payload
    }

    public static func write(
        _ payload: MacWidgetLocalPayload,
        fileManager: FileManager = .default
    ) throws {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw StoreError.appGroupUnavailable
        }
        let data = try JSONEncoder().encode(payload)
        let defaults = UserDefaults(suiteName: appGroupIdentifier)
        defaults?.set(data, forKey: defaultsKey)
        // synchronize() is deprecated and a no-op promise; the load side
        // already prefers whichever channel (defaults or file) wrote last.
        // The file is the source of truth — a failed write throws.
        try write(data, to: container.appendingPathComponent(fileName), fileManager: fileManager)
    }

    public static func write(
        _ payload: MacWidgetLocalPayload,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try write(JSONEncoder().encode(payload), to: url, fileManager: fileManager)
    }

    public static func write(
        _ payload: MacWidgetLocalPayload,
        to userDefaults: UserDefaults
    ) throws {
        userDefaults.set(try JSONEncoder().encode(payload), forKey: defaultsKey)
    }

    private static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
