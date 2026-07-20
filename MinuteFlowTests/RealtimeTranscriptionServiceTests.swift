@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import MinuteFlow

final class RealtimeTranscriptionServiceTests: XCTestCase {
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

    private func audibleBuffer(duration: TimeInterval) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frameCount = AVAudioFrameCount(16_000 * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) { samples[index] = 0.4 }
        return buffer
    }
}

private struct SlowCancellableASRClient: ASRClient {
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        try await Task.sleep(for: .seconds(10))
        return "不应完成"
    }
}
