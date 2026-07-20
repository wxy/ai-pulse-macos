import Foundation

/// CloudKit schema — shared between macOS writer and iOS/watchOS readers.
///
/// Architecture: single record type (`DashboardCache_v1`) with one record
/// per time range. Each record stores a JSON blob of the full dashboard snapshot
/// under the `json` field, plus an `updatedAt` timestamp.
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

    enum Subscription {
        static let dashboardChanges = "dashboard-changes"
    }
}
