import CloudKit
import Combine
import Foundation
import os
import WidgetKit
import AIPulseShared

enum CloudError: Error {
    case noData
    case unavailable
    /// The record's payload version is not the one this client expects.
    /// `macosTooOld` is true when the record was written by an older macOS
    /// format (upgrade macOS); false when the record is newer (upgrade iOS).
    case versionMismatch(macosTooOld: Bool, recordVersion: String?)
}

/// Minimal first-class fields decoded from the top of every snapshot JSON,
/// before full decode — so the version check works even when the payload body
/// can no longer be decoded by this client.
struct SnapshotEnvelope: Codable {
    var payloadVersion: String?
    var writerAppVersion: String?
}

/// Reads the DashboardCache_v2 record synced by macOS.
/// Maintains THREE independent snapshots — one per time range — so each tab
/// always displays its own data, even offline or when a CK fetch fails.
@MainActor
final class CloudDataService: ObservableObject {
    static let shared = CloudDataService()

    /// The snapshot for the currently selected time range.
    @Published var snapshot: DashboardSnapshot?
    @Published var lastUpdated: Date?
    @Published private(set) var pulseEnvelope: CurrentPulseEnvelope?
    @Published private(set) var rangeErrors: [String: String] = [:]
    @Published private(set) var pulseError: String?
    var isPreview: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--iphone-preview")
        #else
        return false
        #endif
    }
    private(set) var currentRange: String = "today"

    /// All three per-range snapshots. Keyed by "today" / "week" / "30d".
    @Published private var snapshots: [String: DashboardSnapshot] = [:]

    static var cloudAvailable: Bool {
        #if targetEnvironment(simulator)
        // Unsigned preview builds have no CloudKit entitlements. Signed
        // simulator builds use the same CloudKit path as devices.
        return (Bundle.main.object(forInfoDictionaryKey: "CloudKitAccessEnabled") as? String)?.uppercased() == "YES"
        #else
        return true
        #endif
    }
    private lazy var database: CKDatabase = {
        let db = CKContainer(identifier: "iCloud.com.wxy.aipulse").privateCloudDatabase
        return db
    }()
    private let log = Logger(subsystem: "com.wxy.aipulse", category: "CloudData")
    private init() {
        if !isPreview { loadLocalCache() }
    }

    // MARK: - Local cache (survives offline / app restart)

    private var localCacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("dashboard_cache.json")
    }

    private func loadLocalCache() {
        guard let data = try? Data(contentsOf: localCacheURL),
              let dict = try? JSONDecoder().decode([String: DashboardSnapshot].self, from: data) else { return }
        // A cache written by a buggy macOS build may still contain poisoned
        // values; sanitize on every read so old data can never reach the UI.
        self.snapshots = dict.filter { PhoneDashboardData.accepts($0.value, range: $0.key) }.mapValues { $0.sanitized() }
        if let data = try? Data(contentsOf: localCacheURL.deletingLastPathComponent().appendingPathComponent("current_pulse_v2.json")),
           let pulse = try? JSONDecoder().decode(CurrentPulseEnvelope.self, from: data), pulse.payloadVersion == CKSchema.payloadVersion { pulseEnvelope = pulse }
        // Default to today on first load (caller should call loadSnapshot(for:) afterward)
        if let today = self.snapshots["today"] { self.snapshot = today }
        log.info("loaded local cache: \(dict.keys.joined(separator: ", "))")
    }

    private func saveLocalCache() {
        guard !isPreview else { return }
        guard let data = try? JSONEncoder().encode(self.snapshots) else { return }
        // Primary cache
        try? data.write(to: localCacheURL, options: .atomic)
        // Widget cache — write to App Group container so Widget Extension can read it
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.wxy.aipulse"
        ) {
            let widgetCacheURL = groupURL.appendingPathComponent("dashboard_cache.json")
            try? FileManager.default.createDirectory(at: groupURL,
                withIntermediateDirectories: true)
            try? data.write(to: widgetCacheURL, options: .atomic)
        }
        // Notify widget to refresh — debounced so a burst of writes (today +
        // week + 30d all landing within the same launch window) collapses
        // into a single WidgetKit reload instead of one per write.
        scheduleWidgetReload()
    }

    private var widgetReloadTask: Task<Void, Never>?

    private func scheduleWidgetReload() {
        widgetReloadTask?.cancel()
        widgetReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard self != nil, !Task.isCancelled else { return }
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Switch the published snapshot to the given time range.
    /// If the range hasn't been fetched yet, clear the snapshot so the UI
    /// shows empty/loading state instead of stale data from another tab.
    func loadSnapshot(for range: String) {
        self.currentRange = range
        self.snapshot = self.snapshots[range]
        self.lastUpdated = self.snapshot?.updatedAt
    }

    /// Returns the range-local snapshot without switching the published data.
    /// DashboardView uses this at body-evaluation time so a tab can never
    /// render another range's breakdown while a CloudKit fetch is in flight.
    func cachedSnapshot(for range: String) -> DashboardSnapshot? {
        snapshots[range]
    }

    private func recordName(for range: String) -> String {
        switch range {
        case "today": return CKSchema.RecordName.today
        case "week":  return CKSchema.RecordName.week
        case "30d":   return CKSchema.RecordName.month
        default:      return "snapshot-v2-\(range)"
        }
    }

    /// Throws `.versionMismatch` unless the record's payloadVersion exactly
    /// matches the version this client expects. Records without a
    /// payloadVersion are legacy (written before versioning) and are treated
    /// as older-than-current — i.e. the macOS side needs upgrading.
    private func checkPayloadVersion(_ envelope: SnapshotEnvelope) throws {
        let expected = CKSchema.payloadVersion
        guard let recordVersion = envelope.payloadVersion else {
            throw CloudError.versionMismatch(macosTooOld: true, recordVersion: nil)
        }
        let cmp = PayloadVersion.compare(recordVersion, expected)
        if cmp == 0 { return }
        throw CloudError.versionMismatch(macosTooOld: cmp < 0, recordVersion: recordVersion)
    }

    private func checkEnvelope(in data: Data) throws {
        guard let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data) else { throw CloudError.noData }
        try checkPayloadVersion(envelope)
    }

    /// Check if CloudKit has data. On success, merge the today record's costs
    /// into the current snapshot WITHOUT replacing breakdown data (repos, trends).
    /// This preserves previously-cached week/30d breakdowns if they can't be
    /// refreshed right now.
    func hasData() async throws -> Bool {
        guard Self.cloudAvailable else { throw CloudError.unavailable }
        // Gated: this is the very first CloudKit call at launch, so it also
        // enforces the minimum spacing after NotificationService's setup()
        // (permission request + CK subscription registration) ran moments
        // earlier. See CloudKitGate for why this matters.
        return try await CloudKitGate.shared.run("hasData(today)") {
            let recordID = CKRecord.ID(recordName: self.recordName(for: "today"))
            do {
                let record = try await self.database.record(for: recordID)
                self.log.info("hasData: record found, json present=\(record[CKSchema.Field.json] != nil)")
                guard record.recordType == CKSchema.recordType,
                      let json = record[CKSchema.Field.json] as? String,
                      let data = json.data(using: .utf8) else {
                    self.log.warning("hasData: json field missing")
                    throw CloudError.noData
                }
                try self.checkEnvelope(in: data)
                let snap: DashboardSnapshot
                do {
                    snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                } catch {
                    self.log.error("hasData: decode failed — \(error.localizedDescription)")
                    throw CloudError.noData
                }
                // Store today's snapshot independently (with CK updatedAt timestamp)
                guard PhoneDashboardData.accepts(snap, range: "today") else { throw CloudError.noData }
                self.snapshots["today"] = snap.sanitized()
                if self.snapshot == nil { self.loadSnapshot(for: "today") }
                self.saveLocalCache()
                // DashboardView.onAppear fires a fetchSnapshot("today") right
                // after this returns — mark it fresh so that call is deduped
                // instead of firing a second, near-simultaneous CK request.
                CloudKitGate.shared.markRecentlyFetched("fetch-today")
                return true
            } catch let cloudError as CloudError {
                throw cloudError
            } catch let ckError as CKError {
                self.log.error("hasData: CKError code=\(ckError.code.rawValue) userInfo=\(ckError.errorUserInfo)")
                switch ckError.code {
                case .unknownItem:
                    throw CloudError.noData
                case .networkUnavailable, .notAuthenticated, .permissionFailure:
                    throw CloudError.unavailable
                default:
                    throw CloudError.unavailable
                }
            } catch {
                self.log.error("hasData: \(error.localizedDescription)")
                throw CloudError.unavailable
            }
        }
    }

    /// Lightweight refresh for watchOS — fetch today snapshot with detailed error reporting.
    func refresh() async {
        guard Self.cloudAvailable else { return }
        let container = CKContainer(identifier: "iCloud.com.wxy.aipulse")
        log.info("refresh: container=\(container.containerIdentifier ?? "nil")")

        do {
            let status = try await CloudKitGate.shared.run("accountStatus") {
                try await container.accountStatus()
            }
            log.info("refresh: account status=\(status.rawValue)")
            switch status {
            case .available: break
            case .noAccount:       log.error("refresh: no iCloud account"); return
            case .restricted:      log.error("refresh: iCloud restricted"); return
            case .couldNotDetermine: log.error("refresh: could not determine iCloud status"); return
            case .temporarilyUnavailable: log.error("refresh: iCloud temporarily unavailable"); return
            @unknown default:      log.error("refresh: unknown iCloud status \(status.rawValue)"); return
            }
        } catch {
            log.error("refresh: accountStatus() threw — \(error.localizedDescription)")
            return
        }

        // Fetch all three time ranges independently.
        log.info("refresh: fetching all ranges")
        await fetchAndStore(range: "today")
        await fetchAndStore(range: "week")
        await fetchAndStore(range: "30d")
        // Reload the currently displayed range so the UI reflects new data
        loadSnapshot(for: currentRange)
    }

    /// Fetch a single snapshot record and store it independently by range.
    /// Each tab always gets its own data — no cross-range merging.
    func fetchAndMergeWeek() async { await fetchAndStore(range: "week") }
    func fetchAndMergeMonth() async { await fetchAndStore(range: "30d") }

    func fetchAndStore(range: String) async {
        guard !isPreview, Self.cloudAvailable else {
            if !isPreview { rangeErrors[range] = "Cloud unavailable" }
            return
        }
        do {
            _ = try await CloudKitGate.shared.runDeduped("fetch(\(range))", dedupeKey: "fetch-\(range)") {
                let record = try await self.database.record(for: CKRecord.ID(recordName: self.recordName(for: range)))
                guard record.recordType == CKSchema.recordType,
                      let json = record[CKSchema.Field.json] as? String, let data = json.data(using: .utf8) else { throw CloudError.noData }
                try self.checkEnvelope(in: data)
                let snap = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
                guard PhoneDashboardData.accepts(snap, range: range) else { throw CloudError.noData }
                self.snapshots[range] = snap.sanitized()
                self.rangeErrors[range] = nil
                self.saveLocalCache()
            }
        } catch {
            rangeErrors[range] = error.localizedDescription
        }
    }

    func fetchCurrentPulse() async {
        guard !isPreview, Self.cloudAvailable else { return }
        do {
            _ = try await CloudKitGate.shared.runDeduped("currentPulse", dedupeKey: "current-pulse") {
                let record = try await self.database.record(for: CKRecord.ID(recordName: "current-pulse"))
                guard record.recordType == "CurrentPulse_v2",
                      let json = record[CKSchema.Field.json] as? String, let data = json.data(using: .utf8) else { throw CloudError.noData }
                let envelope = try JSONDecoder().decode(CurrentPulseEnvelope.self, from: data)
                guard envelope.payloadVersion == CKSchema.payloadVersion else { throw CloudError.noData }
                self.pulseEnvelope = envelope
                self.pulseError = nil
                try? data.write(to: self.localCacheURL.deletingLastPathComponent().appendingPathComponent("current_pulse_v2.json"), options: .atomic)
            }
        } catch { pulseError = error.localizedDescription }
    }

    #if DEBUG
    func installPreview(snapshots: [String: DashboardSnapshot], pulse: CurrentPulseEnvelope) {
        guard isPreview else { return }
        self.snapshots = snapshots
        pulseEnvelope = pulse
        loadSnapshot(for: "today")
    }
    #endif

    /// Fetch a single range AND switch the published snapshot to it.
    /// Called on tab switch — shows that range's data immediately.
    func fetchSnapshot(for range: String = "today") async throws {
        loadSnapshot(for: range)
        await fetchAndStore(range: range)
        if currentRange == range { loadSnapshot(for: range) }
    }
}
