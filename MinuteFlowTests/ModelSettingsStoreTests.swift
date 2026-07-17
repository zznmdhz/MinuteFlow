import Foundation
import XCTest
@testable import MinuteFlow

@MainActor
final class ModelSettingsStoreTests: XCTestCase {
    func testMiMoTokenPlanUsesChatCompletionsForASRAndSummary() {
        let suiteName = "MinuteFlowModelSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ModelSettingsStore(defaults: defaults)

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

    func testUnknownCompatibleServiceUsesAudioTranscriptions() {
        let suiteName = "MinuteFlowCustomSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ModelSettingsStore(defaults: defaults)

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

    func testInvalidBaseURLIsRejected() {
        let suiteName = "MinuteFlowInvalidSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ModelSettingsStore(defaults: defaults)

        settings.baseURL = "not-a-url"
        XCTAssertNil(settings.resolvedASREndpoint)
        XCTAssertFalse(settings.connectionIsConfigured)
    }
}

