import Foundation
import XCTest
@testable import MinuteFlow

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testCoordinatesBothSourcesPauseResumeAndStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let system = MockAudioCaptureService(name: "系统声音")
        let microphone = MockAudioCaptureService(name: "测试麦克风")
        let coordinator = RecordingCoordinator(
            systemAudioService: system,
            microphoneService: microphone,
            repository: LocalMeetingRepository(rootDirectory: root),
            permissionManager: AllowingPermissionManager()
        )
        coordinator.sourceSelection = .both
        coordinator.meetingTitle = "双路录音"

        await coordinator.startRecording()
        XCTAssertEqual(coordinator.status, .recording)
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertEqual(system.outputURL?.lastPathComponent, "system.m4a")
        XCTAssertEqual(microphone.outputURL?.lastPathComponent, "microphone.m4a")

        coordinator.pauseRecording()
        XCTAssertEqual(coordinator.status, .paused)
        XCTAssertEqual(system.pauseCount, 1)
        XCTAssertEqual(microphone.pauseCount, 1)

        coordinator.resumeRecording()
        XCTAssertEqual(coordinator.status, .recording)
        XCTAssertEqual(system.resumeCount, 1)
        XCTAssertEqual(microphone.resumeCount, 1)

        await coordinator.stopRecording()
        XCTAssertEqual(coordinator.status, .completed)
        XCTAssertEqual(system.stopCount, 1)
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(coordinator.currentSession?.title, "双路录音")
    }

    func testContinuesWhenOneSourceFails() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorFallback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let system = MockAudioCaptureService(name: "系统声音")
        system.startError = TestError.failed
        let microphone = MockAudioCaptureService(name: "测试麦克风")
        let coordinator = RecordingCoordinator(
            systemAudioService: system,
            microphoneService: microphone,
            repository: LocalMeetingRepository(rootDirectory: root),
            permissionManager: AllowingPermissionManager()
        )
        coordinator.sourceSelection = .both

        await coordinator.startRecording()

        XCTAssertEqual(coordinator.status, .recording)
        XCTAssertNil(coordinator.currentSession?.systemAudioURL)
        XCTAssertNotNil(coordinator.currentSession?.microphoneAudioURL)
        XCTAssertTrue(coordinator.userMessage?.contains("另一路录音仍在继续") == true)
        await coordinator.stopRecording()
    }
}

private enum TestError: Error {
    case failed
}

private final class MockAudioCaptureService: AudioCaptureService, @unchecked Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    let displayName: String
    var startError: Error?
    private(set) var startCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var stopCount = 0
    private(set) var outputURL: URL?

    init(name: String) {
        displayName = name
    }

    func start(outputURL: URL) async throws {
        startCount += 1
        if let startError { throw startError }
        self.outputURL = outputURL
    }

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() async { stopCount += 1 }
}

private final class AllowingPermissionManager: PermissionManaging, @unchecked Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool { true }
    @MainActor func openSettings(for kind: PermissionKind) {}
}
