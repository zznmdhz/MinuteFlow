import Foundation
import XCTest
@testable import MinuteFlow

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    func testInitializationAndPassiveRefreshNeverRequestOrProbePermission() {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorPassivePermission-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let permissions = TrackingPermissionManager()
        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: MockAudioCaptureService(name: "测试麦克风"),
            repository: LocalMeetingRepository(rootDirectory: root),
            permissionManager: permissions
        )

        coordinator.refreshPermissionStates()

        XCTAssertEqual(permissions.requestCount, 0)
        XCTAssertEqual(permissions.verifyCount, 0)
        XCTAssertGreaterThanOrEqual(permissions.passiveStatusCount, 4)
    }

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
        XCTAssertTrue(system.outputURL?.lastPathComponent.hasSuffix("_双路录音_系统声.m4a") == true)
        XCTAssertTrue(microphone.outputURL?.lastPathComponent.hasSuffix("_双路录音_麦克风.m4a") == true)

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

    func testUnknownSystemPermissionDoesNotTriggerSecondProtectedCaptureCall() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorStalePermission-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let system = MockAudioCaptureService(name: "系统声音")
        let microphone = MockAudioCaptureService(name: "测试麦克风")
        let coordinator = RecordingCoordinator(
            systemAudioService: system,
            microphoneService: microphone,
            repository: LocalMeetingRepository(rootDirectory: root),
            permissionManager: StaleSystemPermissionManager()
        )
        coordinator.sourceSelection = .system

        await coordinator.startRecording()

        XCTAssertEqual(system.startCount, 0)
        XCTAssertEqual(coordinator.status, .failed)
        XCTAssertNil(coordinator.currentSession?.systemAudioURL)
        XCTAssertEqual(coordinator.systemAudioPermission, .denied)
    }

    func testRuntimeSourceFailuresUpdateStateAndSaveWhenAllSourcesStop() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorRuntimeFailure-\(UUID().uuidString)", directoryHint: .isDirectory)
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
        await coordinator.startRecording()

        system.emitError(TestError.failed)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(system.stopCount, 1)
        XCTAssertEqual(coordinator.status, .recording)
        XCTAssertTrue(coordinator.userMessage?.contains("麦克风仍在继续") == true)

        microphone.emitError(TestError.failed)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(microphone.stopCount, 1)
        XCTAssertEqual(coordinator.status, .completed)
        XCTAssertTrue(coordinator.userMessage?.contains("所有录音来源") == true)
    }

    func testOldSummaryCannotReplaceANewRecordingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowSummaryRace-\(UUID().uuidString)")
        let credentialDirectory = root.appending(path: "credentials")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var oldSession = try repository.createSession(title: "会议 A", sourceSelection: .microphone)
        oldSession.recordingStatus = .completed
        let segments = [TranscriptSegment(startTime: 0, endTime: 2, text: "会议 A 内容", source: .microphone, isFinal: true)]
        oldSession.transcriptFileURL = try repository.saveTranscript(segments, sessionID: oldSession.id)
        try repository.save(oldSession)

        let suiteName = "MinuteFlowSummaryRaceDefaults-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = "com.minuteflow.tests.\(UUID().uuidString)"
        let settings = ModelSettingsStore(
            defaults: defaults,
            credentialStore: CredentialStoreAdapter(
                read: { try CredentialStore.read(key: $0, keychainService: service, fallbackDirectory: credentialDirectory) },
                write: { try CredentialStore.write($0, key: $1, keychainService: service, fallbackDirectory: credentialDirectory, allowProtectedFileFallback: $2) }
            )
        )
        settings.asrEnabled = false
        settings.summaryEnabled = true
        settings.summaryModel = "summary-model"
        settings.apiKey = "summary-test-token"
        settings.retrySavingCredential()

        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: MockAudioCaptureService(name: "测试麦克风"),
            repository: repository,
            permissionManager: AllowingPermissionManager(),
            modelSettings: settings,
            summaryClient: DelayedSummaryClient()
        )
        coordinator.selectSession(oldSession)

        let summaryTask = Task { await coordinator.generateSummary() }
        try await Task.sleep(for: .milliseconds(30))
        coordinator.prepareNewRecording()
        coordinator.sourceSelection = .microphone
        coordinator.meetingTitle = "会议 B"
        await coordinator.startRecording()
        let newSessionID = try XCTUnwrap(coordinator.currentSession?.id)

        await summaryTask.value
        XCTAssertEqual(coordinator.currentSession?.id, newSessionID)
        XCTAssertEqual(coordinator.currentSession?.title, "会议 B")
        XCTAssertEqual(coordinator.status, .recording)
        await coordinator.stopRecording()
    }
}

private enum TestError: Error {
    case failed
}

private struct DelayedSummaryClient: SummaryClient {
    func summarize(
        title: String,
        segments: [TranscriptSegment],
        configuration: SummaryConfiguration
    ) async throws -> String {
        try await Task.sleep(for: .milliseconds(120))
        return "# 会议 A 纪要"
    }
}

private final class MockAudioCaptureService: AudioCaptureService, @unchecked Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
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
    func emitError(_ error: any Error) { onError?(error) }
}

private final class AllowingPermissionManager: PermissionManaging, @unchecked Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool { true }
    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState { .authorized }
    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState { .authorized }
    @MainActor func openSettings(for kind: PermissionKind) {}
}

private final class StaleSystemPermissionManager: PermissionManaging, @unchecked Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool { false }
    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState { .unknown }
    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState { .denied }
    @MainActor func openSettings(for kind: PermissionKind) {}
}

private final class TrackingPermissionManager: PermissionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    private var passiveChecks = 0
    private var verifications = 0

    var requestCount: Int { lock.withLock { requests } }
    var passiveStatusCount: Int { lock.withLock { passiveChecks } }
    var verifyCount: Int { lock.withLock { verifications } }

    func requestPermission(for kind: PermissionKind) async -> Bool {
        lock.withLock { requests += 1 }
        return false
    }

    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState {
        lock.withLock { passiveChecks += 1 }
        return kind == .microphone ? .notDetermined : .unknown
    }

    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState {
        lock.withLock { verifications += 1 }
        return .denied
    }

    @MainActor func openSettings(for kind: PermissionKind) {}
}
