import Foundation
import XCTest
@testable import MinuteFlow

final class SpeakerTimelineTests: XCTestCase {
    func testExternalMeetingWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MINUTE_FLOW_SAMPLE_AUDIO"] else {
            throw XCTSkip("Set MINUTE_FLOW_SAMPLE_AUDIO to run the local diarizer against a real meeting.")
        }

        let result = try await LocalSpeakerDiarizer().analyze(audioURL: URL(fileURLWithPath: path))

        XCTAssertFalse(result.turns.isEmpty)
        XCTAssertGreaterThanOrEqual(result.speakerCount, 1)
        XCTAssertTrue(result.turns.allSatisfy { $0.endTime > $0.startTime })
        print("REAL_SAMPLE_DIARIZATION speakers=\(result.speakerCount) turns=\(result.turns.count)")
    }

    func testAdaptiveVADLearnsRoomNoiseAndClosesAfterRealPause() {
        var detector = AdaptiveVoiceActivityDetector()

        for _ in 0..<20 {
            let observation = detector.observe(level: 0.35, duration: 0.05)
            XCTAssertFalse(observation.isSpeech)
        }

        var started = false
        for _ in 0..<8 {
            started = detector.observe(level: 0.63, duration: 0.05).speechStarted || started
        }
        XCTAssertTrue(started)
        XCTAssertTrue(detector.isSpeech)

        var pause: VoiceActivityObservation?
        for _ in 0..<16 {
            pause = detector.observe(level: 0.35, duration: 0.05)
        }
        XCTAssertGreaterThanOrEqual(pause?.trailingSilence ?? 0, 0.7)
    }

    func testSpeakerTurnsSplitRecognitionTimelineAndRemoveProtocolArtifacts() {
        let fragments = [
            TranscriptRecognitionFragment(
                startTime: 0,
                endTime: 4,
                originalText: "大家好 <chinese><chinese>",
                boundaryReason: .forcedHardLimit
            ),
            TranscriptRecognitionFragment(
                startTime: 4,
                endTime: 8,
                originalText: "我来介绍项目",
                boundaryReason: .recordingStopped
            )
        ]
        let segment = TranscriptSegment(
            startTime: 0,
            endTime: 8,
            text: "旧的整段文本",
            source: .microphone,
            isFinal: true,
            recognitionFragments: fragments,
            boundaryReason: .recordingStopped
        )
        let result = SpeakerDiarizationResult(
            version: 1,
            generatedAt: Date(),
            sourceFileName: "meeting.m4a",
            method: "test",
            speakerCount: 2,
            turns: [
                SpeakerTurn(startTime: 0, endTime: 4, speakerID: "speaker-1", confidence: 0.9),
                SpeakerTurn(startTime: 4, endTime: 8, speakerID: "speaker-2", confidence: 0.9)
            ]
        )

        let aligned = TranscriptSpeakerAligner.align(segments: [segment], with: result)

        XCTAssertEqual(aligned.count, 2)
        XCTAssertEqual(aligned.map(\.speakerID), ["speaker-1", "speaker-2"])
        XCTAssertEqual(aligned.map(\.startTime), [0, 4])
        XCTAssertFalse(aligned[0].text.contains("<chinese>"))
    }

    func testRepositoryPersistsDiarizationAlongsideTranscript() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowDiarization-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        let session = try repository.createSession(title: "说话人测试", sourceSelection: .microphone)
        let result = SpeakerDiarizationResult(
            version: 1,
            generatedAt: Date(),
            sourceFileName: "microphone.m4a",
            method: "local-acoustic-v1",
            speakerCount: 1,
            turns: [SpeakerTurn(startTime: 0, endTime: 5, speakerID: "speaker-1", confidence: 0.8)]
        )

        let url = try repository.saveDiarization(result, sessionID: session.id)

        XCTAssertEqual(url.lastPathComponent, "diarization.json")
        let loaded = try XCTUnwrap(repository.loadDiarization(sessionID: session.id))
        XCTAssertEqual(loaded.version, result.version)
        XCTAssertEqual(loaded.method, result.method)
        XCTAssertEqual(loaded.speakerCount, result.speakerCount)
        XCTAssertEqual(loaded.turns, result.turns)
    }
}
