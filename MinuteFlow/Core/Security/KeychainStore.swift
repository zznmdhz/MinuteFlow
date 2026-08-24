import Foundation
import Security

struct KeychainStoreError: LocalizedError, Equatable {
    let status: OSStatus

    var errorDescription: String? {
        let systemMessage = SecCopyErrorMessageString(status, nil) as String? ?? "未知钥匙串错误"
        return "钥匙串操作失败（\(status)）：\(systemMessage)"
    }
}

enum KeychainStore {
    static func read(
        key: String,
        service: String = "com.minuteflow.models"
    ) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw KeychainStoreError(status: status) }
        guard
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else { throw KeychainStoreError(status: errSecDecode) }
        return value
    }

    static func write(
        _ value: String,
        key: String,
        service: String = "com.minuteflow.models"
    ) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if value.isEmpty {
            let status = SecItemDelete(baseQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainStoreError(status: status)
            }
            return
        }

        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(status: updateStatus)
        }

        var insertQuery = baseQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrLabel as String] = "MinuteFlow AI Token"
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainStoreError(status: addStatus) }
    }
}
