import Foundation
import XCTest
@testable import MinuteFlow

final class MeetingRepositoryTests: XCTestCase {
    func testRecoversStaleActiveSessionAsInterrupted() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowRepositoryRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "异常退出", sourceSelection: .microphone)
        session.recordingStatus = .recording
        try repository.save(session)

        let recovered = try XCTUnwrap(repository.loadRecentSessions().first)
        XCTAssertEqual(recovered.recordingStatus, .interrupted)
        XCTAssertNotNil(recovered.endTime)
        XCTAssertFalse(recovered.recordingStatus.isActive)
        XCTAssertEqual(try repository.loadRecentSessions().first?.recordingStatus, .interrupted)
    }

    func testCreatesSeparateAudioDestinationsAndPersistsMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowRepositoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "录音测试", sourceSelection: .both)

        XCTAssertTrue(session.systemAudioURL?.lastPathComponent.hasSuffix("_录音测试_系统声.m4a") == true)
        XCTAssertTrue(session.microphoneAudioURL?.lastPathComponent.hasSuffix("_录音测试_麦克风.m4a") == true)
        XCTAssertNotEqual(session.systemAudioURL, session.microphoneAudioURL)

        session.recordingStatus = .completed
        session.duration = 42
        try repository.save(session)

        let recent = try repository.loadRecentSessions()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.title, "录音测试")
        XCTAssertEqual(recent.first?.duration, 42)
        XCTAssertEqual(recent.first?.recordingStatus, .completed)

        let segments = [
            TranscriptSegment(
                startTime: 0,
                endTime: 5,
                text: "这是测试逐字稿。",
                source: .system,
                isFinal: true
            )
        ]
        _ = try repository.saveTranscript(segments, sessionID: session.id)
        XCTAssertEqual(try repository.loadTranscript(sessionID: session.id), segments)

        _ = try repository.saveSummary("# 测试纪要", sessionID: session.id)
        XCTAssertEqual(try repository.loadSummary(sessionID: session.id), "# 测试纪要")

        try repository.deleteSession(id: session.id)
        XCTAssertTrue(try repository.loadRecentSessions().isEmpty)
    }

    func testRecoversInterruptedMixAndCompletedButUnregisteredOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowMixRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "混音恢复", sourceSelection: .both)
        session.recordingStatus = .completed
        session.mixState = .processing
        try repository.save(session)

        var recovered = try XCTUnwrap(repository.loadRecentSessions().first)
        XCTAssertEqual(recovered.mixState, .failed)
        XCTAssertTrue(recovered.mixMessage?.contains("可重新生成") == true)

        let mixedURL = repository.mixedAudioURL(for: session.id)
        try Data("validated-mixed-placeholder".utf8).write(to: mixedURL, options: .atomic)
        recovered.mixState = .processing
        recovered.mixedAudioURL = nil
        try repository.save(recovered)

        let completedOutput = try XCTUnwrap(repository.loadRecentSessions().first)
        XCTAssertEqual(completedOutput.mixState, .ready)
        XCTAssertEqual(completedOutput.mixedAudioURL, mixedURL)
    }
}
