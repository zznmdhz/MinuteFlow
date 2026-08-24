@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import MinuteFlow

final class RealtimeTranscriptionServiceTests: XCTestCase {
    func testHotStartedServiceKeepsMeetingTimelineOffset() async throws {
        let client = RecordingASRClient(responses: [(.milliseconds(0), "热启动内容")])
        let service = RemoteRealtimeTranscriptionService(client: client)
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: configuration,
            maximumChunkDuration: 15,
            timelineOffset: 42
        )
        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 1), source: .microphone))
        let segments = await service.finish()

        XCTAssertEqual(segments.first?.startTime ?? 0, 42, accuracy: 0.01)
        XCTAssertGreaterThan(segments.first?.endTime ?? 0, 42)
    }

    func testThreeSecondPreviewIsReplaceableAndNeverPartOfFinalResults() async throws {
        let client = RecordingASRClient(responses: [
            (.milliseconds(0), "临时预览"),
            (.milliseconds(0), "最终完整内容")
        ])
        let previews = SegmentBox()
        let service = RemoteRealtimeTranscriptionService(client: client)
        service.onPreview = { previews.append($0) }
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: configuration,
            maximumChunkDuration: 15
        )

        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 3.2), source: .microphone))
        try await Task.sleep(for: .milliseconds(100))
        let preview = try XCTUnwrap(previews.values.first)
        XCTAssertFalse(preview.isFinal)
        XCTAssertEqual(preview.text, "临时预览")

        service.append(CapturedAudioBuffer(buffer: try silentBuffer(duration: 0.8), source: .microphone))
        let finished = await service.finish()
        let final = try XCTUnwrap(finished.first)
        XCTAssertTrue(final.isFinal)
        XCTAssertEqual(final.text, "最终完整内容")
        XCTAssertEqual(final.id, preview.id, "The UI can replace preview in place with the final paragraph")
    }

    func testContinuousSpeechDoesNotFinalizeAtThreeSeconds() async throws {
        let client = RecordingASRClient(responses: [
            (.milliseconds(0), "临时内容"),
            (.milliseconds(0), "连续讲话内容")
        ])
        let finals = SegmentBox()
        let service = RemoteRealtimeTranscriptionService(client: client)
        service.onSegment = { finals.append($0) }
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: configuration,
            maximumChunkDuration: 15
        )

        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 4), source: .microphone))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(client.requestCount, 1, "Three seconds produces only the replaceable preview request")
        XCTAssertTrue(finals.values.isEmpty, "Three seconds is no longer a final transcript boundary")

        let segments = await service.finish()
        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(segments.map(\.text), ["连续讲话内容"])
        XCTAssertEqual(segments.first?.boundaryReason, .recordingStopped)
    }

    func testNaturalPauseFinalizesOneUtterance() async throws {
        let client = RecordingASRClient(responses: [
            (.milliseconds(0), "临时预览"),
            (.milliseconds(0), "自然停顿后定稿")
        ])
        let service = RemoteRealtimeTranscriptionService(client: client)
        try service.start(
            sessionID: UUID(),
            sources: [.system],
            configuration: configuration,
            maximumChunkDuration: 15
        )

        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 4), source: .system))
        try await Task.sleep(for: .milliseconds(100))
        service.append(CapturedAudioBuffer(buffer: try silentBuffer(duration: 0.8), source: .system))
        let segments = await service.finish()

        XCTAssertEqual(client.requestCount, 2)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.boundaryReason, .naturalPause)
        XCTAssertEqual(segments.first?.recognitionFragments?.count, 1)
        XCTAssertEqual(segments.first?.originalText, "自然停顿后定稿")
    }

    func testUserPauseCreatesAHardParagraphBoundary() async throws {
        let client = RecordingASRClient(responses: [
            (.milliseconds(0), "暂停之前"),
            (.milliseconds(0), "暂停之后")
        ])
        let service = RemoteRealtimeTranscriptionService(client: client)
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: configuration,
            maximumChunkDuration: 15
        )

        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 1), source: .microphone))
        service.splitCurrentUtterances(reason: .userPause)
        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 1), source: .microphone))
        let segments = await service.finish()

        XCTAssertEqual(segments.map(\.text), ["暂停之前", "暂停之后"])
        XCTAssertEqual(segments.map(\.boundaryReason), [.userPause, .recordingStopped])
    }

    func testHardLimitFragmentsAreAssembledAfterOutOfOrderResponses() async throws {
        let client = AudioContentASRClient()
        let service = RemoteRealtimeTranscriptionService(client: client)
        try service.start(
            sessionID: UUID(),
            sources: [.system],
            configuration: configuration,
            maximumChunkDuration: 15
        )

        for _ in 0..<15 {
            service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 1, amplitude: 0.2), source: .system))
        }
        try await Task.sleep(for: .milliseconds(50))
        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 0.2, amplitude: 0.2), source: .system))
        for _ in 0..<15 {
            service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 1, amplitude: 0.4), source: .system))
        }
        service.append(CapturedAudioBuffer(buffer: try silentBuffer(duration: 0.8), source: .system))
        let segments = await service.finish()

        XCTAssertEqual(client.requestCount, 4)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.text, "这是连续讲话需要保留字段才能判断现状")
        XCTAssertEqual(
            segments.first?.originalText,
            "这是连续讲话需要保留字段\n保留字段才能判断现状\n判断现状"
        )
        XCTAssertEqual(segments.first?.recognitionFragments?.count, 3)
        let overlap = try XCTUnwrap(segments.first?.recognitionFragments?.dropFirst().first?.overlapBefore)
        XCTAssertEqual(overlap, 0.45, accuracy: 0.03)
        XCTAssertEqual(segments.first?.boundaryReason, .naturalPause)
    }

    func testContinuousSpeechIsCappedIntoReadableParagraphs() async throws {
        let client = RecordingASRClient(responses: [(.milliseconds(0), "连续讲话")])
        let service = RemoteRealtimeTranscriptionService(client: client)
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: configuration,
            maximumChunkDuration: 10
        )

        for _ in 0..<46 {
            service.append(CapturedAudioBuffer(
                buffer: try audibleBuffer(duration: 1),
                source: .microphone
            ))
        }
        let segments = await service.finish()

        XCTAssertEqual(segments.count, 2)
        XCTAssertLessThanOrEqual(segments[0].endTime - segments[0].startTime, 41)
        XCTAssertEqual(segments[0].boundaryReason, .forcedHardLimit)
        XCTAssertEqual(segments[1].boundaryReason, .recordingStopped)
    }

    func testLegacyTranscriptSegmentDecodesWithoutNewTraceabilityFields() throws {
        let data = Data(#"{"id":"CB79E03C-9FEA-4418-BE8A-B122167D4DC8","startTime":0,"endTime":3,"text":"旧文本","source":"system","isFinal":true}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: data)
        XCTAssertEqual(decoded.text, "旧文本")
        XCTAssertNil(decoded.recognitionFragments)
        XCTAssertNil(decoded.boundaryReason)
    }

    func testFinishHasGlobalTimeoutAndPreservesSafeManifest() async throws {
        let pendingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-Pending-ASR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pendingDirectory) }
        let service = RemoteRealtimeTranscriptionService(
            client: SlowCancellableASRClient(),
            finishTimeout: .milliseconds(150),
            pendingDirectory: pendingDirectory
        )
        try service.start(
            sessionID: UUID(),
            sources: [.microphone],
            configuration: ASRConfiguration(
                transport: .miMoChatAudio,
                endpoint: URL(string: "https://models.example.com/v1/chat/completions")!,
                model: "test-asr",
                apiKey: "must-not-be-persisted",
                language: "zh"
            ),
            maximumChunkDuration: 2
        )
        service.append(CapturedAudioBuffer(buffer: try audibleBuffer(duration: 2), source: .microphone))

        let started = ContinuousClock.now
        _ = await service.finish()
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(1))

        try await Task.sleep(for: .milliseconds(100))
        let files = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
        let manifestURL = try XCTUnwrap(files.first(where: { $0.pathExtension == "json" }))
        let manifestText = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(manifestText.contains("test-asr"))
        XCTAssertTrue(manifestText.contains("microphone"))
        XCTAssertFalse(manifestText.contains("must-not-be-persisted"))
        XCTAssertTrue(files.contains(where: { $0.pathExtension == "wav" }))
    }

    private func audibleBuffer(duration: TimeInterval, amplitude: Float = 0.4) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = AVAudioFrameCount(16_000 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) { samples[index] = amplitude }
        return buffer
    }

    private func silentBuffer(duration: TimeInterval) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = AVAudioFrameCount(16_000 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        return buffer
    }

    private var configuration: ASRConfiguration {
        ASRConfiguration(
            transport: .miMoChatAudio,
            endpoint: URL(string: "https://models.example.com/v1/chat/completions")!,
            model: "test-asr",
            apiKey: "test-token",
            language: "zh"
        )
    }
}

private final class RecordingASRClient: ASRClient, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Duration, String)]
    private var count = 0

    init(responses: [(Duration, String)]) {
        self.responses = responses
    }

    var requestCount: Int { lock.withLock { count } }

    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        let response: (Duration, String) = lock.withLock {
            let index = count
            count += 1
            return responses[min(index, responses.count - 1)]
        }
        if response.0 > .zero { try await Task.sleep(for: response.0) }
        return response.1
    }
}

private final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptSegment] = []
    var values: [TranscriptSegment] { lock.withLock { storage } }
    func append(_ segment: TranscriptSegment) { lock.withLock { storage.append(segment) } }
}

private final class AudioContentASRClient: ASRClient, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var requestCount: Int { lock.withLock { count } }

    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        lock.withLock { count += 1 }
        let file = try AVAudioFile(forReading: wavURL)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else { throw AudioCaptureError.cannotCreateAudioBuffer }
        try file.read(into: buffer)
        let samples = buffer.floatChannelData?[0]
        let mean = samples.map { pointer in
            (0..<Int(buffer.frameLength)).reduce(Float.zero) { $0 + abs(pointer[$1]) }
                / Float(max(1, buffer.frameLength))
        } ?? 0

        if duration < 2 {
            try await Task.sleep(for: .milliseconds(10))
            return "判断现状"
        }
        if duration < 5 { return "预览内容" }
        if mean < 0.3 {
            try await Task.sleep(for: .milliseconds(180))
            return "这是连续讲话需要保留字段"
        }
        try await Task.sleep(for: .milliseconds(20))
        return "保留字段才能判断现状"
    }
}

private struct SlowCancellableASRClient: ASRClient {
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        try await Task.sleep(for: .seconds(10))
        return "不应完成"
    }
}
