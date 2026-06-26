import Foundation
import Security

/// Manages API keys in the macOS Keychain.
/// Each provider's key is stored under the service "ai-pulse/{providerId}".
final class ApiKeyManager {
    static let shared = ApiKeyManager()

    private func serviceName(for providerId: String) -> String {
        "ai-pulse/\(providerId)"
    }

    func get(_ providerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: providerId),
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    func set(_ providerId: String, key: String) {
        // Delete existing first
        delete(providerId)

        guard let data = key.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: providerId),
            kSecValueData as String: data,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func delete(_ providerId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName(for: providerId),
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// All provider IDs that have a stored key.
    func configuredProviderIds() -> [String] {
        ProviderRegistry.all.compactMap { get($0.id) != nil ? $0.id : nil }
    }
}
