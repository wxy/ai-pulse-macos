import Foundation

/// CloudKit record keys shared between macOS writer and iOS/watchOS readers.
enum CKRecordType: String {
    case dailyStat     = "DailyStat"
    case dailyCodeChange = "DailyCodeChange"
    case providerCost  = "ProviderCost"
}

/// Fields within each CKRecord type.
enum CKField {
    static let date       = "date"
    static let cost       = "cost"
    static let calls      = "calls"
    static let tokens     = "tokens"
    static let netLines   = "netLines"
    static let costPerLine = "costPerLine"
    static let added      = "added"
    static let deleted    = "deleted"
    static let providerId = "providerId"
    static let spend      = "spend"
}
