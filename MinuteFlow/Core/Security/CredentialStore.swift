import Foundation

enum CredentialStorageBackend: Equatable, Sendable {
    case keychain
    case protectedFile
}

struct StoredCredentialResult: Equatable, Sendable {
    let value: String
    let backend: CredentialStorageBackend?
}

enum CredentialStore {
    static func read(
        key: String,
        keychainService: String = "com.minuteflow.models",
        fallbackDirectory: URL = defaultFallbackDirectory
    ) throws -> StoredCredentialResult {
        if let keychainValue = try? KeychainStore.read(key: key, service: keychainService),
           !keychainValue.isEmpty {
            return StoredCredentialResult(value: keychainValue, backend: .keychain)
        }

        let url = fallbackURL(for: key, directory: fallbackDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return StoredCredentialResult(value: "", backend: nil)
        }
        let data = try Data(contentsOf: url)
        let record = try JSONDecoder().decode(ProtectedCredentialRecord.self, from: data)
        return StoredCredentialResult(value: record.value, backend: .protectedFile)
    }

    @discardableResult
    static func write(
        _ value: String,
        key: String,
        keychainService: String = "com.minuteflow.models",
        fallbackDirectory: URL = defaultFallbackDirectory
    ) throws -> CredentialStorageBackend? {
        let fallbackURL = fallbackURL(for: key, directory: fallbackDirectory)

        if value.isEmpty {
            try? KeychainStore.write("", key: key, service: keychainService)
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                try FileManager.default.removeItem(at: fallbackURL)
            }
            return nil
        }

        do {
            try KeychainStore.write(value, key: key, service: keychainService)
            let verified = try KeychainStore.read(key: key, service: keychainService)
            guard verified == value else { throw CredentialStoreError.verificationFailed }
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                try? FileManager.default.removeItem(at: fallbackURL)
            }
            return .keychain
        } catch {
            try writeProtectedFile(value, to: fallbackURL, directory: fallbackDirectory)
            let verified = try readProtectedFile(from: fallbackURL)
            guard verified == value else { throw CredentialStoreError.verificationFailed }
            return .protectedFile
        }
    }

    static let defaultFallbackDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!
        .appending(path: "MinuteFlow/Secure", directoryHint: .isDirectory)

    private static func writeProtectedFile(_ value: String, to url: URL, directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(ProtectedCredentialRecord(value: value))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readProtectedFile(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(ProtectedCredentialRecord.self, from: data).value
    }

    private static func fallbackURL(for key: String, directory: URL) -> URL {
        let safeKey = key.map { character in
            character.isLetter || character.isNumber || character == "." ? character : "_"
        }
        return directory.appending(path: "\(String(safeKey)).credential")
    }
}

private struct ProtectedCredentialRecord: Codable {
    let version: Int
    let value: String

    init(value: String) {
        version = 1
        self.value = value
    }
}

private enum CredentialStoreError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        "凭据保存后无法回读验证。"
    }
}
