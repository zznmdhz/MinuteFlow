import Foundation
import XCTest
@testable import MinuteFlow

final class RemoteDocumentFormattingClientTests: XCTestCase {
    func testLongTranscriptIsFormattedInOrderWithoutSummaryMerge() async throws {
        let counter = DocumentRequestCounter()
        DocumentFixtureURLProtocol.handler = { request in
            let index = counter.increment()
            let body = try Self.requestBody(request)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("document-model"))
            XCTAssertTrue(text.contains("不做摘要"))
            return "{\"choices\":[{\"message\":{\"content\":\"## 整理部分-\(index)\"}}]}"
        }
        defer { DocumentFixtureURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DocumentFixtureURLProtocol.self]
        let client = RemoteDocumentFormattingClient(
            session: URLSession(configuration: configuration),
            maximumChunkCharacters: 2_000
        )
        let segments = (0..<6).map { index in
            TranscriptSegment(
                startTime: TimeInterval(index * 20),
                endTime: TimeInterval(index * 20 + 20),
                text: String(repeating: "应当保留的逐字稿内容。", count: 160),
                source: .microphone,
                isFinal: true
            )
        }

        let result = try await client.format(
            title: "产品讨论",
            segments: segments,
            configuration: DocumentFormattingConfiguration(
                endpoint: URL(string: "https://models.example.com/v1/chat/completions")!,
                model: "document-model",
                apiKey: "document-key"
            )
        )

        XCTAssertGreaterThan(counter.value, 1)
        XCTAssertTrue(result.hasPrefix("# 产品讨论"))
        XCTAssertTrue(result.contains("## 整理部分-1"))
        XCTAssertTrue(result.contains("## 整理部分-\(counter.value)"))
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

private final class DocumentRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class DocumentFixtureURLProtocol: URLProtocol, @unchecked Sendable {
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
