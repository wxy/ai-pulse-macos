import Foundation
import GRDB

/// Stores API keys in UserDefaults (not Keychain).
///
/// Keychain was considered but `kSecAttrAccessibleAfterFirstUnlock` still
/// periodically prompts for the login keychain password on macOS, which is
/// unacceptable for a menu-bar tool.  These are API keys for read-only
/// usage/balance checks — not payment credentials — so UserDefaults is an
/// acceptable trade-off.
final class ApiKeyManager: @unchecked Sendable {
    static let shared = ApiKeyManager()
    private let defaults = UserDefaults.standard
    private let prefix = "apikey_"

    func get(_ providerId: String) -> String? {
        defaults.string(forKey: prefix + providerId)
    }

    func set(_ providerId: String, key: String) {
        defaults.set(key, forKey: prefix + providerId)
    }

    func delete(_ providerId: String) {
        defaults.removeObject(forKey: prefix + providerId)
        // Historical observations belong to the user's local record, not to
        // the credential lifecycle. Read paths already hide a provider without
        // a configured key, so removing access must not erase prior snapshots.
    }

    func configuredProviderIds() -> [String] {
        ProviderRegistry.all.compactMap { get($0.id) != nil ? $0.id : nil }
    }
}
