@preconcurrency import AVFoundation
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
            permissionManager: permissions,
            modelSettings: makeTestSettings()
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
            permissionManager: AllowingPermissionManager(),
            modelSettings: makeTestSettings()
        )
        coordinator.sourceSelection = .both
        coordinator.meetingTitle = "双路录音"

        await coordinator.startRecording()
        XCTAssertEqual(coordinator.status, .recording)
        XCTAssertEqual(system.startCount, 1)
        XCTAssertEqual(microphone.startCount, 1)
        XCTAssertTrue(system.outputURL?.lastPathComponent.hasSuffix("_系统声音.m4a") == true)
        XCTAssertTrue(microphone.outputURL?.lastPathComponent.hasSuffix("_麦克风.m4a") == true)

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

    func testStoppingBothSourcesGeneratesCompletePlaybackAndKeepsRawTracks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorMix-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        let system = MockAudioCaptureService(name: "系统声音", writesPlaceholderFile: true)
        let microphone = MockAudioCaptureService(name: "测试麦克风", writesPlaceholderFile: true)
        let mixer = MockAudioMixer()
        let repository = LocalMeetingRepository(rootDirectory: root)
        let coordinator = RecordingCoordinator(
            systemAudioService: system,
            microphoneService: microphone,
            repository: repository,
            permissionManager: AllowingPermissionManager(),
            modelSettings: makeTestSettings(),
            audioMixer: mixer
        )
        coordinator.sourceSelection = .both

        await coordinator.startRecording()
        let now = ProcessInfo.processInfo.systemUptime
        microphone.emit(try timedPacket(source: .microphone, monotonicTime: now + 0.2, startFrame: 0))
        system.emit(try timedPacket(source: .system, monotonicTime: now, startFrame: 0))
        system.emit(try timedPacket(source: .system, monotonicTime: now + 1.0, startFrame: 480))
        microphone.emit(try timedPacket(source: .microphone, monotonicTime: now + 1.2, startFrame: 480))
        coordinator.pauseRecording()
        coordinator.resumeRecording()
        let resumedAt = ProcessInfo.processInfo.systemUptime
        system.emit(try timedPacket(source: .system, monotonicTime: resumedAt, startFrame: 960))
        microphone.emit(try timedPacket(source: .microphone, monotonicTime: resumedAt + 0.2, startFrame: 960))
        let systemURL = try XCTUnwrap(system.outputURL)
        let microphoneURL = try XCTUnwrap(microphone.outputURL)
        let systemBefore = try Data(contentsOf: systemURL)
        let microphoneBefore = try Data(contentsOf: microphoneURL)

        await coordinator.stopRecording()

        let session = try XCTUnwrap(coordinator.currentSession)
        XCTAssertEqual(session.mixState, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(session.mixedAudioURL).path))
        XCTAssertEqual(try Data(contentsOf: systemURL), systemBefore)
        XCTAssertEqual(try Data(contentsOf: microphoneURL), microphoneBefore)
        let request = await mixer.receivedRequest()
        XCTAssertEqual(request?.inputs.count, 2)
        let systemStart = try XCTUnwrap(request?.inputs.first(where: { $0.source == .system })?.epochs.first?.logicalStartFrame)
        let microphoneStart = try XCTUnwrap(request?.inputs.first(where: { $0.source == .microphone })?.epochs.first?.logicalStartFrame)
        XCTAssertEqual(Double(microphoneStart - systemStart), 9_600, accuracy: 400)
        for input in request?.inputs ?? [] {
            let epochs = input.epochs.sorted { $0.logicalStartFrame < $1.logicalStartFrame }
            for pair in zip(epochs, epochs.dropFirst()) {
                XCTAssertGreaterThanOrEqual(
                    pair.1.logicalStartFrame,
                    pair.0.logicalStartFrame + pair.0.frameCount,
                    "Pause/resume epochs must never overlap on the mixed timeline"
                )
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.mixManifestURL(for: session.id).path))
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
            permissionManager: AllowingPermissionManager(),
            modelSettings: makeTestSettings()
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
            permissionManager: StaleSystemPermissionManager(),
            modelSettings: makeTestSettings()
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
            permissionManager: AllowingPermissionManager(),
            modelSettings: makeTestSettings()
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
        let credentialBox = TestCredentialBox()
        let settings = ModelSettingsStore(
            defaults: defaults,
            credentialStore: CredentialStoreAdapter(
                read: { _ in StoredCredentialResult(value: credentialBox.read(), backend: credentialBox.read().isEmpty ? nil : .protectedFile) },
                write: { value, _, _ in
                    credentialBox.write(value)
                    return value.isEmpty ? nil : .protectedFile
                }
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

    func testSummaryNeverReceivesNonFinalPreviewSegments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowSummaryFinalOnly-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "最终文本", sourceSelection: .microphone)
        session.recordingStatus = .completed
        let preview = TranscriptSegment(startTime: 0, endTime: 3, text: "不应进入总结", source: .microphone, isFinal: false)
        let final = TranscriptSegment(startTime: 3, endTime: 6, text: "最终内容", source: .microphone, isFinal: true)
        session.transcriptFileURL = try repository.saveTranscript([preview, final], sessionID: session.id)
        try repository.save(session)

        let credentialBox = TestCredentialBox()
        credentialBox.write("summary-token")
        let settings = ModelSettingsStore(
            defaults: UserDefaults(suiteName: "MinuteFlowSummaryFinalOnly-\(UUID().uuidString)")!,
            credentialStore: CredentialStoreAdapter(
                read: { _ in StoredCredentialResult(value: credentialBox.read(), backend: .protectedFile) },
                write: { value, _, _ in credentialBox.write(value); return .protectedFile }
            )
        )
        settings.asrEnabled = false
        settings.summaryEnabled = true
        settings.summaryModel = "summary-model"
        let capture = SummarySegmentsBox()
        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: MockAudioCaptureService(name: "测试麦克风"),
            repository: repository,
            permissionManager: AllowingPermissionManager(),
            modelSettings: settings,
            summaryClient: CapturingSummaryClient(box: capture)
        )
        coordinator.selectSession(session)

        await coordinator.generateSummary()

        XCTAssertEqual(capture.values.map(\.text), ["最终内容"])
    }

    func testSidebarRenamePersistsAndKeepsStableSessionDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowRename-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "旧名称", sourceSelection: .microphone)
        session.recordingStatus = .completed
        try repository.save(session)
        let originalDirectory = repository.sessionDirectory(for: session.id)
        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: MockAudioCaptureService(name: "测试麦克风"),
            repository: repository,
            permissionManager: AllowingPermissionManager(),
            modelSettings: makeTestSettings()
        )
        coordinator.selectSession(session)

        coordinator.renameSession(session, to: "新名称")

        XCTAssertEqual(coordinator.currentSession?.title, "新名称")
        XCTAssertEqual(try repository.loadRecentSessions().first?.title, "新名称")
        XCTAssertEqual(repository.sessionDirectory(for: session.id), originalDirectory)
    }

    func testAIFormattedDocumentUsesFinalSegmentsAndPersistsMarkdown() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowFormattedDocument-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "排版测试", sourceSelection: .microphone)
        session.recordingStatus = .completed
        let preview = TranscriptSegment(startTime: 0, endTime: 3, text: "临时文字", source: .microphone, isFinal: false)
        let final = TranscriptSegment(startTime: 3, endTime: 6, text: "最终正文", source: .microphone, isFinal: true)
        session.transcriptFileURL = try repository.saveTranscript([preview, final], sessionID: session.id)
        try repository.save(session)

        let credentialBox = TestCredentialBox()
        credentialBox.write("document-token")
        let settings = ModelSettingsStore(
            defaults: UserDefaults(suiteName: "MinuteFlowFormattedDocument-\(UUID().uuidString)")!,
            credentialStore: CredentialStoreAdapter(
                read: { _ in StoredCredentialResult(value: credentialBox.read(), backend: .protectedFile) },
                write: { value, _, _ in credentialBox.write(value); return .protectedFile }
            )
        )
        settings.asrEnabled = false
        settings.summaryEnabled = true
        settings.summaryModel = "document-model"
        let capture = DocumentSegmentsBox()
        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: MockAudioCaptureService(name: "测试麦克风"),
            repository: repository,
            permissionManager: AllowingPermissionManager(),
            modelSettings: settings,
            documentFormattingClient: CapturingDocumentFormattingClient(box: capture)
        )
        coordinator.selectSession(session)

        await coordinator.generateFormattedDocument()

        XCTAssertEqual(capture.values.map(\.text), ["最终正文"])
        XCTAssertEqual(coordinator.formattedDocumentMarkdown, "# 已整理文稿")
        XCTAssertEqual(try repository.loadFormattedDocument(sessionID: session.id), "# 已整理文稿")
        XCTAssertEqual(coordinator.currentSession?.formattedDocumentFileURL?.lastPathComponent, "AI排版文稿.md")
    }

    func testSavingASRWhileRecordingHotStartsLiveTranscription() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowCoordinatorHotASR-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let credentialBox = TestCredentialBox()
        let defaults = UserDefaults(suiteName: "MinuteFlowHotASRDefaults-\(UUID().uuidString)")!
        let settings = ModelSettingsStore(
            defaults: defaults,
            credentialStore: CredentialStoreAdapter(
                read: { _ in
                    let value = credentialBox.read()
                    return StoredCredentialResult(
                        value: value,
                        backend: value.isEmpty ? nil : .protectedFile
                    )
                },
                write: { value, _, _ in
                    credentialBox.write(value)
                    return value.isEmpty ? nil : .protectedFile
                }
            )
        )
        settings.asrEnabled = true
        settings.asrModel = "mimo-v2.5-asr"
        let microphone = MockAudioCaptureService(name: "测试麦克风")
        let realtime = RemoteRealtimeTranscriptionService(client: HotStartASRClient())
        let coordinator = RecordingCoordinator(
            systemAudioService: MockAudioCaptureService(name: "系统声音"),
            microphoneService: microphone,
            repository: LocalMeetingRepository(rootDirectory: root),
            permissionManager: AllowingPermissionManager(),
            modelSettings: settings,
            transcriptionService: realtime
        )
        coordinator.sourceSelection = .microphone
        await coordinator.startRecording()
        XCTAssertTrue(coordinator.transcriptSegments.isEmpty)

        settings.apiKey = "hot-start-token"
        settings.retrySavingCredential()
        try await Task.sleep(for: .milliseconds(350))
        microphone.emit(CapturedAudioBuffer(
            buffer: try hotStartBuffer(duration: 1, amplitude: 0.35),
            source: .microphone
        ))
        microphone.emit(CapturedAudioBuffer(
            buffer: try hotStartBuffer(duration: 0.8, amplitude: 0),
            source: .microphone
        ))
        try await Task.sleep(for: .milliseconds(80))
        await coordinator.stopRecording()

        XCTAssertEqual(coordinator.transcriptSegments.first?.text, "热配置已经生效")
        XCTAssertEqual(coordinator.transcriptionActivity, "转写与说话人时间轴已保存")
    }
}

private func timedPacket(
    source: TranscriptSource,
    monotonicTime: TimeInterval,
    startFrame: Int64
) throws -> CapturedAudioBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    return CapturedAudioBuffer(
        buffer: buffer,
        source: source,
        timing: AudioCaptureTiming(
            monotonicTime: monotonicTime,
            outputStartFrame: startFrame,
            outputFrameCount: 480,
            outputSampleRate: 48_000,
            timestampQuality: .captureClock
        )
    )
}

private func hotStartBuffer(
    duration: TimeInterval,
    amplitude: Float
) throws -> AVAudioPCMBuffer {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    let frames = AVAudioFrameCount(duration * format.sampleRate)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    for frame in 0..<Int(frames) {
        buffer.floatChannelData![0][frame] = amplitude * sin(Float(frame) * 0.08)
    }
    return buffer
}

@MainActor
private func makeTestSettings() -> ModelSettingsStore {
    let defaults = UserDefaults(suiteName: "MinuteFlowCoordinatorTests-\(UUID().uuidString)")!
    let settings = ModelSettingsStore(
        defaults: defaults,
        credentialStore: CredentialStoreAdapter(
            read: { _ in StoredCredentialResult(value: "", backend: nil) },
            write: { _, _, _ in nil }
        )
    )
    settings.asrEnabled = false
    settings.summaryEnabled = false
    return settings
}

private enum TestError: Error {
    case failed
}

private struct HotStartASRClient: ASRClient {
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        "热配置已经生效"
    }
}

private final class TestCredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""

    func read() -> String { lock.withLock { value } }
    func write(_ newValue: String) { lock.withLock { value = newValue } }
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

private struct CapturingSummaryClient: SummaryClient {
    let box: SummarySegmentsBox

    func summarize(
        title: String,
        segments: [TranscriptSegment],
        configuration: SummaryConfiguration
    ) async throws -> String {
        box.store(segments)
        return "# 最终纪要"
    }
}

private final class SummarySegmentsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    var values: [TranscriptSegment] { lock.withLock { segments } }
    func store(_ value: [TranscriptSegment]) { lock.withLock { segments = value } }
}

private struct CapturingDocumentFormattingClient: DocumentFormattingClient {
    let box: DocumentSegmentsBox

    func format(
        title: String,
        segments: [TranscriptSegment],
        configuration: DocumentFormattingConfiguration
    ) async throws -> String {
        box.store(segments)
        return "# 已整理文稿"
    }
}

private final class DocumentSegmentsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = []
    var values: [TranscriptSegment] { lock.withLock { segments } }
    func store(_ value: [TranscriptSegment]) { lock.withLock { segments = value } }
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
    private let writesPlaceholderFile: Bool

    init(name: String, writesPlaceholderFile: Bool = false) {
        displayName = name
        self.writesPlaceholderFile = writesPlaceholderFile
    }

    func start(outputURL: URL) async throws {
        startCount += 1
        if let startError { throw startError }
        self.outputURL = outputURL
        if writesPlaceholderFile {
            try Data("raw-\(displayName)".utf8).write(to: outputURL, options: .atomic)
        }
    }

    func pause() { pauseCount += 1 }
    func resume() { resumeCount += 1 }
    func stop() async { stopCount += 1 }
    func emitError(_ error: any Error) { onError?(error) }
    func emit(_ packet: CapturedAudioBuffer) { onAudioBuffer?(packet) }
}

private actor MockAudioMixer: AudioMixing {
    private var request: AudioMixRequest?

    func mix(_ request: AudioMixRequest) async throws -> AudioMixResult {
        self.request = request
        try FileManager.default.createDirectory(
            at: request.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("mixed".utf8).write(to: request.outputURL, options: .atomic)
        return AudioMixResult(
            outputURL: request.outputURL,
            duration: request.expectedDuration ?? 0,
            includedSources: request.inputs.map(\.source),
            peak: 0.5,
            finalScale: 1,
            degraded: false,
            warnings: []
        )
    }

    func receivedRequest() -> AudioMixRequest? { request }
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
