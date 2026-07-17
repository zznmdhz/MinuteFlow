import Foundation
import Security

enum KeychainStore {
    private static let service = "com.minuteflow.models"

    static func read(key: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard
            SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return "" }
        return value
    }

    static func write(_ value: String, key: String) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if value.isEmpty {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var insertQuery = baseQuery
            insertQuery[kSecValueData as String] = data
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }
}

