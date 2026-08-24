import Foundation
import XCTest
@testable import MinuteFlow

@MainActor
final class ModelSettingsStoreTests: XCTestCase {
    func testMiMoTokenPlanUsesChatCompletionsForASRAndSummary() throws {
        let suiteName = "MinuteFlowModelSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (settings, directory) = makeSettings(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory) }

        settings.baseURL = "https://token-plan-cn.xiaomimimo.com/v1"
        settings.asrModel = "mimo-v2.5-asr"

        XCTAssertEqual(settings.detectedASRTransport, .miMoChatAudio)
        XCTAssertEqual(
            settings.resolvedASREndpoint?.absoluteString,
            "https://token-plan-cn.xiaomimimo.com/v1/chat/completions"
        )
        XCTAssertEqual(
            settings.resolvedSummaryEndpoint?.absoluteString,
            "https://token-plan-cn.xiaomimimo.com/v1/chat/completions"
        )
    }

    func testUnknownCompatibleServiceUsesAudioTranscriptions() throws {
        let suiteName = "MinuteFlowCustomSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (settings, directory) = makeSettings(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory) }

        settings.baseURL = "https://models.example.com/v1/"

        XCTAssertEqual(settings.detectedASRTransport, .openAIAudioTranscription)
        XCTAssertEqual(
            settings.resolvedASREndpoint?.absoluteString,
            "https://models.example.com/v1/audio/transcriptions"
        )
        XCTAssertEqual(
            settings.resolvedSummaryEndpoint?.absoluteString,
            "https://models.example.com/v1/chat/completions"
        )
    }

    func testInvalidBaseURLIsRejected() throws {
        let suiteName = "MinuteFlowInvalidSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let (settings, directory) = makeSettings(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory) }

        settings.baseURL = "not-a-url"
        XCTAssertNil(settings.resolvedASREndpoint)
        XCTAssertFalse(settings.connectionIsConfigured)
    }

    func testLegacyThreeSecondChunkSettingMigratesToSmartFifteenSecondLimit() {
        let suiteName = "MinuteFlowChunkMigrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(3.0, forKey: "models.asr.maximumChunkDuration")
        let (settings, directory) = makeSettings(defaults: defaults)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(settings.maximumChunkDuration, 15)
        XCTAssertEqual(defaults.double(forKey: "models.asr.maximumChunkDuration"), 15)
    }

    func testTokenRequiresExplicitSaveAndLoadsMaskedAcrossInstances() throws {
        let suiteName = "MinuteFlowTokenLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ModelSettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let box = CredentialMemoryBox()
        let adapter = CredentialStoreAdapter(
            read: { _ in box.read() },
            write: { value, _, _ in
                if value.isEmpty {
                    box.clear()
                    return nil
                }
                box.save(value)
                return .keychain
            }
        )

        var first: ModelSettingsStore? = ModelSettingsStore(defaults: defaults, credentialStore: adapter)
        first?.apiKey = "persisted-test-token"
        XCTAssertEqual(first?.credentialPersistenceState, .unsaved)
        XCTAssertEqual(first?.activeAPIKey, "")
        first?.retrySavingCredential()
        XCTAssertEqual(first?.activeAPIKey, "persisted-test-token")
        first = nil

        let reopened = ModelSettingsStore(defaults: defaults, credentialStore: adapter)
        XCTAssertEqual(reopened.activeAPIKey, "persisted-test-token")
        XCTAssertEqual(reopened.apiKey, "")
        XCTAssertTrue(reopened.connectionIsConfigured)

        reopened.clearSavedCredential()
        XCTAssertEqual(reopened.credentialPersistenceState, .missing)
        XCTAssertEqual(reopened.activeAPIKey, "")
    }

    func testKeychainFailureNeverSilentlyFallsBackToAFile() {
        let suiteName = "MinuteFlowExplicitFallbackTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let box = CredentialMemoryBox()
        let adapter = CredentialStoreAdapter(
            read: { _ in box.read() },
            write: { value, _, allowFallback in
                if value.isEmpty {
                    box.clear()
                    return nil
                }
                guard allowFallback else { throw TestCredentialError.keychainUnavailable }
                box.save(value)
                return .protectedFile
            }
        )
        let settings = ModelSettingsStore(defaults: defaults, credentialStore: adapter)
        settings.apiKey = "explicit-fallback-token"

        settings.retrySavingCredential()
        if case .fallbackAvailable = settings.credentialPersistenceState {} else {
            XCTFail("Keychain failure must require explicit fallback consent")
        }
        XCTAssertEqual(box.read().value, "")
        XCTAssertEqual(settings.activeAPIKey, "")

        settings.saveCredentialUsingProtectedFile()
        XCTAssertEqual(settings.credentialPersistenceState, .savedToProtectedFile)
        XCTAssertEqual(box.read().value, "explicit-fallback-token")
        XCTAssertEqual(settings.activeAPIKey, "explicit-fallback-token")
    }

    private func makeSettings(defaults: UserDefaults) -> (ModelSettingsStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ModelSettings-\(UUID().uuidString)")
        return (ModelSettingsStore(defaults: defaults, credentialStore: makeCredentialAdapter(directory: directory)), directory)
    }

    private func makeCredentialAdapter(directory: URL) -> CredentialStoreAdapter {
        let service = "com.minuteflow.tests.\(UUID().uuidString)"
        return CredentialStoreAdapter(
            read: { try CredentialStore.read(key: $0, keychainService: service, fallbackDirectory: directory) },
            write: { try CredentialStore.write($0, key: $1, keychainService: service, fallbackDirectory: directory, allowProtectedFileFallback: $2) }
        )
    }
}

private enum TestCredentialError: LocalizedError {
    case keychainUnavailable
    var errorDescription: String? { "测试钥匙串不可用" }
}

private final class CredentialMemoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func read() -> StoredCredentialResult {
        lock.withLock { StoredCredentialResult(value: value, backend: value.isEmpty ? nil : .protectedFile) }
    }

    func save(_ newValue: String) {
        lock.withLock { value = newValue }
    }

    func clear() {
        lock.withLock { value = "" }
    }
}
