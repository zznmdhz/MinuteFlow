import Foundation
import XCTest
@testable import MinuteFlow

final class RemoteSummaryClientTests: XCTestCase {
    func testLongTranscriptUsesChunkSummariesBeforeFinalSummary() async throws {
        let counter = RequestCounter()
        SummaryFixtureURLProtocol.handler = { request in
            let count = counter.increment()
            let body = try Self.requestBody(request)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("summary-model"))
            return "{\"choices\":[{\"message\":{\"content\":\"summary-\(count)\"}}]}"
        }
        defer { SummaryFixtureURLProtocol.handler = nil }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SummaryFixtureURLProtocol.self]
        let client = RemoteSummaryClient(
            session: URLSession(configuration: sessionConfiguration),
            maximumChunkCharacters: 2_000
        )
        let segments = (0..<8).map { index in
            TranscriptSegment(
                startTime: TimeInterval(index * 30),
                endTime: TimeInterval(index * 30 + 30),
                text: String(repeating: "长会议事实内容。", count: 180),
                source: .microphone,
                isFinal: true
            )
        }

        let result = try await client.summarize(
            title: "长会议",
            segments: segments,
            configuration: SummaryConfiguration(
                endpoint: URL(string: "https://models.example.com/v1/chat/completions")!,
                model: "summary-model",
                apiKey: "summary-key",
                prompt: "生成最终纪要"
            )
        )

        XCTAssertGreaterThan(counter.value, 2)
        XCTAssertEqual(result, "summary-\(counter.value)")
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

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class SummaryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> String)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let responseBody = try XCTUnwrap(Self.handler)(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
