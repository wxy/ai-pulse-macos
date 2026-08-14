import Foundation

/// CloudKit schema constants shared by CloudSyncService (macOS).
///
/// Architecture: single `DashboardCache_v1` record type with one record
/// per time range. Each record stores a JSON blob under `json`, plus `updatedAt`.
enum CKSchema {
    static let recordType = "DashboardCache_v1"

    /// JSON payload format version. Bump ONLY when the DashboardSnapshot JSON
    /// structure changes, and set it to the macOS app version that introduces
    /// the new format (e.g. "1.2.4"). MUST stay in sync with
    /// Suites/Shared/Models/CloudKitSchema.swift.
    static let payloadVersion = "1.2.4"

    /// Version of the macOS app currently writing snapshots.
    static var writerAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    enum RecordName {
        static let today = "snapshot-today"
        static let week  = "snapshot-week"
        static let month = "snapshot-30d"
    }

    enum Field {
        static let json      = "json"
        static let updatedAt = "updatedAt"
    }

    enum SpendAlert {
        static let recordType = "SpendAlert_v1"
        static let recordName = "alert-latest"

        enum Field {
            static let json      = "json"
            static let updatedAt = "updatedAt"
        }
    }
}
