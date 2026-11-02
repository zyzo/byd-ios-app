import Foundation
import Security

/// The car's Bluetooth key (from provision_ble_key.py). Stored only in the iOS Keychain.
struct BleKey: Codable, Equatable {
    var vin: String
    var macAddress: String?
    var dkey: String
    var keyNumber: Int
    var keyValidTo: Double?
}

enum BleKeyStore {
    private static let service = AppConfig.bundleID + ".blekey"
    private static let account = "default"

    static func load() -> BleKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(BleKey.self, from: data)
    }

    static func save(_ key: BleKey) throws {
        let data = try JSONEncoder().encode(key)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
