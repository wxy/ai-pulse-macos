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
        return try load(from: container.appendingPathComponent(fileName))
    }

    public static func load(from url: URL) throws -> MacWidgetLocalPayload? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let payload = try JSONDecoder().decode(
            MacWidgetLocalPayload.self,
            from: Data(contentsOf: url)
        )
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
        try write(payload, to: container.appendingPathComponent(fileName), fileManager: fileManager)
    }

    public static func write(
        _ payload: MacWidgetLocalPayload,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }
}
