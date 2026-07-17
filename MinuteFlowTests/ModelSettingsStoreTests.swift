import Foundation
import XCTest
@testable import MinuteFlow

@MainActor
final class ModelSettingsStoreTests: XCTestCase {
    func testOfficialProviderEndpointsAndModels() {
        let suiteName = "MinuteFlowModelSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ModelSettingsStore(defaults: defaults)

        settings.sttProvider = .xiaomiMiMo
        XCTAssertEqual(settings.resolvedSTTModel, "mimo-v2.5-asr")
        XCTAssertEqual(settings.resolvedSTTEndpoint?.host, "api.xiaomimimo.com")

        settings.sttProvider = .zhipuGLM
        XCTAssertEqual(settings.resolvedSTTModel, "glm-asr-2512")
        XCTAssertEqual(settings.resolvedSTTEndpoint?.host, "open.bigmodel.cn")

        settings.summaryProvider = .deepSeek
        XCTAssertEqual(settings.summaryModel, "deepseek-chat")
        XCTAssertEqual(settings.resolvedSummaryEndpoint?.host, "api.deepseek.com")
    }

    func testCustomEndpointsAppendCompatiblePaths() {
        let suiteName = "MinuteFlowCustomSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ModelSettingsStore(defaults: defaults)

        settings.sttProvider = .customOpenAICompatible
        settings.sttBaseURL = "https://models.example.com/v1/"
        XCTAssertEqual(
            settings.resolvedSTTEndpoint?.absoluteString,
            "https://models.example.com/v1/audio/transcriptions"
        )

        settings.summaryProvider = .customOpenAICompatible
        settings.summaryBaseURL = "https://models.example.com/v1"
        XCTAssertEqual(
            settings.resolvedSummaryEndpoint?.absoluteString,
            "https://models.example.com/v1/chat/completions"
        )
    }
}

