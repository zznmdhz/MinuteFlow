@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import MinuteFlow

final class PostRecordingTranscriptionServiceTests: XCTestCase {
    func testExternalSavedMeetingWhenProvided() async throws {
        guard
            let path = ProcessInfo.processInfo.environment["MINUTE_FLOW_POST_AUDIO"],
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("Set MINUTE_FLOW_POST_AUDIO to validate chunking against a real saved meeting.")
        }
        let client = PostTestASRClient()
        let service = PostRecordingTranscriptionService(client: client)
        let segments = PostSegmentBox()
        try await service.transcribe(
            audioURL: URL(fileURLWithPath: path),
            sessionID: UUID(),
            source: .mixed,
            startingAt: 0,
            configuration: ASRConfiguration(
                transport: .miMoChatAudio,
                endpoint: URL(string: "https://example.com/v1/chat/completions")!,
                model: "test-asr",
                apiKey: "not-sent-by-mock",
                language: "auto"
            ),
            maximumChunkDuration: 15,
            onSegment: { segments.append($0) },
            onProgress: { _ in }
        )

        XCTAssertGreaterThan(segments.values.count, 10)
        XCTAssertGreaterThan(segments.values.last?.endTime ?? 0, 1_700)
        XCTAssertEqual(client.requestCount, segments.values.count)
    }

    func testSavedAudioIsSplitOnSilenceAndKeepsTimelineOffset() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "MinuteFlow-PostTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appending(path: "meeting.wav")
        try makeSpeechPauseSpeechAudio(at: audioURL)

        let client = PostTestASRClient()
        let service = PostRecordingTranscriptionService(client: client)
        let segments = PostSegmentBox()
        let progress = PostProgressBox()
        try await service.transcribe(
            audioURL: audioURL,
            sessionID: UUID(),
            source: .mixed,
            startingAt: 1,
            configuration: ASRConfiguration(
                transport: .openAIAudioTranscription,
                endpoint: URL(string: "https://example.com/v1/audio/transcriptions")!,
                model: "test-asr",
                apiKey: "test-token",
                language: "auto"
            ),
            maximumChunkDuration: 15,
            onSegment: { segments.append($0) },
            onProgress: { progress.append($0) }
        )

        XCTAssertGreaterThanOrEqual(segments.values.count, 1)
        XCTAssertTrue(segments.values.allSatisfy { $0.isFinal && $0.source == .mixed })
        XCTAssertGreaterThanOrEqual(segments.values.first?.startTime ?? 0, 1)
        XCTAssertEqual(progress.values.last?.fraction ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(client.requestCount, segments.values.count)
    }

    private func makeSpeechPauseSpeechAudio(at url: URL) throws {
        let sampleRate = 16_000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for (duration, amplitude) in [(1.4, Float(0.45)), (0.9, 0), (1.4, 0.45), (0.9, 0)] {
            let frames = AVAudioFrameCount(duration * sampleRate)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![0][frame] = amplitude * sin(Float(frame) * 0.08)
            }
            try file.write(from: buffer)
        }
    }
}

private final class PostTestASRClient: ASRClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int { lock.withLock { requests } }

    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        lock.withLock { requests += 1 }
        return "历史录音片段"
    }
}

private final class PostSegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptSegment] = []
    var values: [TranscriptSegment] { lock.withLock { storage } }
    func append(_ value: TranscriptSegment) { lock.withLock { storage.append(value) } }
}

private final class PostProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PostTranscriptionProgress] = []
    var values: [PostTranscriptionProgress] { lock.withLock { storage } }
    func append(_ value: PostTranscriptionProgress) { lock.withLock { storage.append(value) } }
}
