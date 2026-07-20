import Foundation

/// CloudKit schema constants shared by CloudSyncService (macOS).
///
/// Architecture: single `DashboardCache_v1` record type with one record
/// per time range. Each record stores a JSON blob under `json`, plus `updatedAt`.
enum CKSchema {
    static let recordType = "DashboardCache_v1"

    enum RecordName {
        static let today = "snapshot-today"
        static let week  = "snapshot-week"
        static let month = "snapshot-30d"
    }

    enum Field {
        static let json      = "json"
        static let updatedAt = "updatedAt"
    }
}
