import Foundation

/// CloudKit schema — shared between macOS writer and iOS/watchOS readers.
///
/// Architecture: single record type (`DashboardCache_v1`) with one record
/// per time range. Each record stores a JSON blob of the full dashboard snapshot
/// under the `json` field, plus an `updatedAt` timestamp.
enum CKSchema {
    static let recordType = "DashboardCache_v1"

    /// JSON payload format version the reader accepts (exact match). Bump ONLY
    /// when the DashboardSnapshot JSON structure changes, and set it to the
    /// macOS app version that introduces the new format (e.g. "1.2.4").
    /// MUST stay in sync with Sources/Sync/CloudKitSchema.swift (macOS).
    static let payloadVersion = "1.2.4"

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

    enum SpendAlert {
        static let recordType = "SpendAlert_v1"
        static let recordName = "alert-latest"

        enum Field {
            static let json      = "json"
            static let updatedAt = "updatedAt"
        }

        enum Subscription {
            static let changes = "spend-alert-changes"
        }
    }
}
