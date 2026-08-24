import Foundation
import XCTest
@testable import MinuteFlow

final class APIRequestAuthenticationTests: XCTestCase {
    func testMiMoTokenPlanUsesAPIKeyHeader() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://token-plan-cn.xiaomimimo.com/v1/chat/completions"))
        var request = URLRequest(url: endpoint)

        APIRequestAuthentication.apply(apiKey: "test-token", endpoint: endpoint, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "test-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGenericCompatibleServiceUsesBearerHeader() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://models.example.com/v1/audio/transcriptions"))
        var request = URLRequest(url: endpoint)

        APIRequestAuthentication.apply(apiKey: "test-key", endpoint: endpoint, to: &request)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "api-key"))
    }
}
