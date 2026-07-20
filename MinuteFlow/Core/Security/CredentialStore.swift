import CryptoKit
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
        return StoredCredentialResult(value: try readProtectedFile(from: url), backend: .protectedFile)
    }

    @discardableResult
    static func write(
        _ value: String,
        key: String,
        keychainService: String = "com.minuteflow.models",
        fallbackDirectory: URL = defaultFallbackDirectory,
        allowProtectedFileFallback: Bool = false
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
            guard allowProtectedFileFallback else { throw error }
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
        let plaintext = Data(value.utf8)
        let sealedBox = try AES.GCM.seal(plaintext, using: fallbackEncryptionKey)
        guard let combined = sealedBox.combined else { throw CredentialStoreError.encryptionFailed }
        let data = try JSONEncoder().encode(ProtectedCredentialRecord(sealedData: combined))
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readProtectedFile(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if let record = try? JSONDecoder().decode(ProtectedCredentialRecord.self, from: data) {
            let sealedBox = try AES.GCM.SealedBox(combined: record.sealedData)
            let plaintext = try AES.GCM.open(sealedBox, using: fallbackEncryptionKey)
            guard let value = String(data: plaintext, encoding: .utf8) else {
                throw CredentialStoreError.invalidCredentialData
            }
            return value
        }

        // Migrate the v1 fallback written by earlier preview builds. The old value is
        // read once and immediately replaced with an encrypted v2 record.
        let legacy = try JSONDecoder().decode(LegacyProtectedCredentialRecord.self, from: data)
        try writeProtectedFile(legacy.value, to: url, directory: url.deletingLastPathComponent())
        return legacy.value
    }

    private static func fallbackURL(for key: String, directory: URL) -> URL {
        let safeKey = key.map { character in
            character.isLetter || character.isNumber || character == "." ? character : "_"
        }
        return directory.appending(path: "\(String(safeKey)).credential")
    }

    private static var fallbackEncryptionKey: SymmetricKey {
        let userID = getuid()
        let context = "MinuteFlow.Credential.v2|\(userID)|\(FileManager.default.homeDirectoryForCurrentUser.path)|com.minuteflow.app"
        return SymmetricKey(data: SHA256.hash(data: Data(context.utf8)))
    }
}

private struct ProtectedCredentialRecord: Codable {
    let version: Int
    let sealedData: Data

    init(sealedData: Data) {
        version = 2
        self.sealedData = sealedData
    }
}

private struct LegacyProtectedCredentialRecord: Codable {
    let version: Int
    let value: String
}

private enum CredentialStoreError: LocalizedError {
    case verificationFailed
    case encryptionFailed
    case invalidCredentialData

    var errorDescription: String? {
        switch self {
        case .verificationFailed: "凭据保存后无法回读验证。"
        case .encryptionFailed: "无法加密本机凭据。"
        case .invalidCredentialData: "本机凭据内容已损坏。"
        }
    }
}
