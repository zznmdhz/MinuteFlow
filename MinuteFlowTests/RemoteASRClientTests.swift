import Foundation
import XCTest
@testable import MinuteFlow

final class RemoteASRClientTests: XCTestCase {
    override func tearDown() {
        RequestFixtureURLProtocol.handler = nil
        super.tearDown()
    }

    func testMiMoTokenPlanRequestContainsAudioProtocolAndAPIKeyHeader() async throws {
        let wavURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let expectation = XCTestExpectation(description: "request intercepted")

        RequestFixtureURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://token-plan-cn.xiaomimimo.com/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "secret-test-value")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.requestBody(request)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "mimo-v2.5-asr")
            XCTAssertEqual(json["stream"] as? Bool, false)
            let bodyText = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(bodyText.contains("input_audio"))
            let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
            let content = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
            let inputAudio = try XCTUnwrap(content.first?["input_audio"] as? [String: Any])
            XCTAssertTrue((inputAudio["data"] as? String)?.hasPrefix("data:audio/wav;base64,") == true)
            XCTAssertTrue(bodyText.contains("\"language\":\"zh\""))
            expectation.fulfill()
            return (200, #"{"choices":[{"message":{"content":"测试成功"}}]}"#)
        }

        let text = try await makeClient().transcribe(
            wavURL: wavURL,
            configuration: ASRConfiguration(
                transport: .miMoChatAudio,
                endpoint: URL(string: "https://token-plan-cn.xiaomimimo.com/v1/chat/completions")!,
                model: "mimo-v2.5-asr",
                apiKey: "secret-test-value",
                language: "zh"
            )
        )
        await fulfillment(of: [expectation], timeout: 1)
        XCTAssertEqual(text, "测试成功")
    }

    func testCompatibleMultipartUsesBearerAndAudioTranscriptions() async throws {
        let wavURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }

        RequestFixtureURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer compatible-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            let body = String(decoding: try Self.requestBody(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model\""))
            XCTAssertTrue(body.contains("whisper-compatible"))
            XCTAssertTrue(body.contains("name=\"file\""))
            return (200, #"{"text":"multipart ok"}"#)
        }

        let text = try await makeClient().transcribe(
            wavURL: wavURL,
            configuration: ASRConfiguration(
                transport: .openAIAudioTranscription,
                endpoint: URL(string: "https://models.example.com/v1/audio/transcriptions")!,
                model: "whisper-compatible",
                apiKey: "compatible-key",
                language: "auto"
            )
        )
        XCTAssertEqual(text, "multipart ok")
    }

    func testServerErrorIsBoundedAndActionable() async throws {
        let wavURL = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: wavURL) }
        RequestFixtureURLProtocol.handler = { _ in
            (429, #"{"error":{"message":"rate limited"}}"#)
        }

        do {
            _ = try await makeClient().transcribe(
                wavURL: wavURL,
                configuration: ASRConfiguration(
                    transport: .openAIAudioTranscription,
                    endpoint: URL(string: "https://models.example.com/v1/audio/transcriptions")!,
                    model: "model",
                    apiKey: "key",
                    language: "auto"
                )
            )
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("429"))
            XCTAssertTrue(error.localizedDescription.contains("自动重试"))
            XCTAssertLessThan(error.localizedDescription.count, 400)
        }
    }

    private func makeClient() -> RemoteASRClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RequestFixtureURLProtocol.self]
        return RemoteASRClient(session: URLSession(configuration: configuration))
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "MinuteFlow-ASR-Test-\(UUID().uuidString).wav")
        try Data("RIFF-test-audio".utf8).write(to: url)
        return url
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }
}

private final class RequestFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
