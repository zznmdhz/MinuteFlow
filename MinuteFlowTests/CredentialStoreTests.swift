import Foundation
import XCTest
@testable import MinuteFlow

final class CredentialStoreTests: XCTestCase {
    func testCredentialPersistsAndCanBeUpdatedWhenKeychainIsUnavailable() throws {
        let service = "com.minuteflow.tests.\(UUID().uuidString)"
        let account = "token"
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-CredentialTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            _ = try? CredentialStore.write("", key: account, keychainService: service, fallbackDirectory: directory)
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertEqual(
            try CredentialStore.read(key: account, keychainService: service, fallbackDirectory: directory).value,
            ""
        )

        let firstBackend = try CredentialStore.write(
            "first-test-value",
            key: account,
            keychainService: service,
            fallbackDirectory: directory,
            allowProtectedFileFallback: true
        )
        XCTAssertNotNil(firstBackend)
        if firstBackend == .protectedFile {
            let directoryPermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            )
            let credentialURL = directory.appending(path: "token.credential")
            let filePermissions = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: credentialURL.path)[.posixPermissions] as? NSNumber
            )
            XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
            XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)
            let rawData = try Data(contentsOf: credentialURL)
            XCTAssertFalse(String(decoding: rawData, as: UTF8.self).contains("first-test-value"))
        }
        XCTAssertEqual(
            try CredentialStore.read(key: account, keychainService: service, fallbackDirectory: directory).value,
            "first-test-value"
        )

        try CredentialStore.write(
            "updated-test-value",
            key: account,
            keychainService: service,
            fallbackDirectory: directory,
            allowProtectedFileFallback: true
        )
        XCTAssertEqual(
            try CredentialStore.read(key: account, keychainService: service, fallbackDirectory: directory).value,
            "updated-test-value"
        )
    }
}
