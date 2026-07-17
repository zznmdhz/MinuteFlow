import Foundation
import XCTest
@testable import MinuteFlow

final class MeetingRepositoryTests: XCTestCase {
    func testCreatesSeparateAudioDestinationsAndPersistsMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowRepositoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "录音测试", sourceSelection: .both)

        XCTAssertEqual(session.systemAudioURL?.lastPathComponent, "system.m4a")
        XCTAssertEqual(session.microphoneAudioURL?.lastPathComponent, "microphone.m4a")
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
}

