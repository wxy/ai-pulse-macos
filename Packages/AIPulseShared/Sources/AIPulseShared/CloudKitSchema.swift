import Foundation

/// CloudKit schema constants shared by the macOS writer and the
/// iOS/watchOS/widget readers.
///
/// Architecture: a single `DashboardCache_v2` record type with one record per
/// time range. Each record stores a JSON blob of the full dashboard snapshot
/// under the `json` field, plus an `updatedAt` timestamp.
///
/// 2.x intentionally uses a separate record type from the 1.x contract so a
/// legacy writer cannot overwrite trusted-data snapshots. There is no v1
/// fallback: readers either receive a matching v2 payload or show no-data /
/// version states.
public enum CKSchema {
    public static let recordType = "DashboardCache_v2"

    /// JSON payload format version the reader accepts (exact match). Bump ONLY
    /// when the `DashboardSnapshot` JSON structure changes, and set it to the
    /// major contract version that introduces the new format.
    public static let payloadVersion = "2.0.0"

    #if os(macOS)
    /// Version of the macOS app currently writing snapshots.
    public static var writerAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }
    #endif

    public enum RecordName {
        public static let today = "snapshot-today"
        public static let week = "snapshot-week"
        public static let month = "snapshot-30d"
    }

    public enum Field {
        public static let json = "json"
        public static let updatedAt = "updatedAt"
    }

    public enum Subscription {
        /// A new ID is required so an upgraded 1.x client does not mistake its
        /// old DashboardCache_v1 subscription for a DashboardCache_v2 one.
        public static let dashboardChanges = "dashboard-v2-changes"
        public static let spendAlertChanges = "spend-alert-changes"
    }

    public enum SpendAlert {
        public static let recordType = "SpendAlert_v1"
        public static let recordName = "alert-latest"

        public enum Field {
            public static let json = "json"
            public static let updatedAt = "updatedAt"
        }

        public enum Subscription {
            public static let changes = "spend-alert-changes"
        }
    }
}

public enum PayloadVersion {
    /// Compares two "X.Y.Z" version strings numerically; returns -1 / 0 / 1.
    public static func compare(_ a: String?, _ b: String?) -> Int {
        let pa = parts(a ?? "")
        let pb = parts(b ?? "")
        for i in 0..<3 {
            if pa[i] != pb[i] { return pa[i] < pb[i] ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ s: String) -> [Int] {
        let comps = s.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        return [comps.count > 0 ? comps[0] : 0,
                comps.count > 1 ? comps[1] : 0,
                comps.count > 2 ? comps[2] : 0]
    }
}
