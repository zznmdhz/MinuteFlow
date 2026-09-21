import Foundation
import Combine

@main
struct RegressionChecks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            checks += 1
            print("PASS: \(label)")
        }
        let monitor = RecordingActivityMonitor()
        monitor.reset(at: 100)
        check(monitor.sample(at: 1899).silentFor == 1799, "silence boundary before 30 minutes")
        check(monitor.sample(at: 1900).silentFor == 1800, "silence boundary at 30 minutes")
        monitor.receive(0.4, microphone: true, at: 1900)
        check(monitor.sample(at: 2000).silentFor == 100, "microphone resets silence")
        monitor.receive(0.5, microphone: false, at: 2000)
        check(monitor.sample(at: 2050).silentFor == 50, "system audio resets silence")
        monitor.receive(.nan, microphone: true, at: 2060)
        monitor.receive(0.01, microphone: true, at: 2070)
        check(monitor.sample(at: 2100).silentFor == 100, "noise floor and invalid samples ignored")
        monitor.reset(at: 2200)
        check(monitor.sample(at: 2201).silentFor == 1, "resume resets guard")
        monitor.receive(0.8, microphone: true, at: 2201)
        monitor.receive(0.2, microphone: true, at: 2201)
        check(monitor.sample(at: 2201).microphone == 0.8, "meter retains interval peak")
        check(monitor.sample(at: 2201).microphone == 0, "stale meter peak clears")

        let root = FileManager.default.temporaryDirectory.appending(path: "MinuteFlowRegression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        var session = try repository.createSession(title: "回归测试", sourceSelection: .microphone)
        session.recordingStatus = .recording
        try repository.save(session)
        check(try repository.loadRecentSessions().first?.recordingStatus == .recording,
              "refresh does not interrupt live recording")
        let restarted = LocalMeetingRepository(rootDirectory: root)
        check(try restarted.loadRecentSessions().first?.recordingStatus == .interrupted,
              "fresh repository recovers interrupted recording")
        session.recordingStatus = .completed
        try repository.save(session)
        let oldDirectory = repository.sessionDirectory(for: session.id)
        session = try repository.renameSession(session, to: "重命名测试")
        check(repository.sessionDirectory(for: session.id).lastPathComponent == "重命名测试",
              "directory cache follows rename")
        check(!FileManager.default.fileExists(atPath: oldDirectory.path), "old directory not recreated")
        let segments = [TranscriptSegment(startTime: 0, endTime: 1, text: "验证保存", source: .microphone, isFinal: true)]
        _ = try repository.saveTranscript(segments, sessionID: session.id)
        check(try repository.loadTranscript(sessionID: session.id) == segments, "transcript survives renamed directory")
        let fragments = [
            TranscriptRecognitionFragment(startTime: 0, endTime: 1, originalText: "第一句", boundaryReason: .naturalPause),
            TranscriptRecognitionFragment(startTime: 10, endTime: 11, originalText: "第三句", boundaryReason: .naturalPause)
        ]
        let alignment = SpeakerDiarizationResult(version: 1, generatedAt: Date(), sourceFileName: "test",
            method: "test", speakerCount: 2,
            turns: [SpeakerTurn(startTime: 0, endTime: 20, speakerID: "speaker-1", confidence: 1)])
        let aligned = TranscriptSpeakerAligner.align(segments: [
            TranscriptSegment(startTime: 0, endTime: 11, text: "第一句第三句", source: .system,
                isFinal: true, recognitionFragments: fragments),
            TranscriptSegment(startTime: 5, endTime: 6, text: "第二句", source: .microphone, isFinal: true)
        ], with: alignment)
        check(aligned.map(\.startTime) == [0, 5, 10], "speaker fragments remain chronological across sources")
        let overlapping = TranscriptSpeakerAligner.align(segments: [
            TranscriptSegment(startTime: 0, endTime: 5, text: "系统", source: .system, isFinal: true),
            TranscriptSegment(startTime: 1, endTime: 4, text: "麦克风", source: .microphone, isFinal: true)
        ], with: alignment)
        check(overlapping.count == 2, "different audio sources never merge into one source label")

        let defaults = UserDefaults(suiteName: "MinuteFlowRegression-\(UUID())")!
        let settings = ModelSettingsStore(defaults: defaults, credentialStore: CredentialStoreAdapter(
            read: { _ in StoredCredentialResult(value: "", backend: nil) }, write: { _, _, _ in nil }))
        settings.asrEnabled = false
        settings.summaryEnabled = false
        let system = TestCapture()
        let microphone = TestCapture()
        let coordinator = RecordingCoordinator(systemAudioService: system, microphoneService: microphone,
            repository: repository, permissionManager: TestPermissions(), modelSettings: settings,
            locationProvider: TestLocation())
        let previousSource = UserDefaults.standard.object(forKey: "defaultAudioSource")
        let previousTimeout = UserDefaults.standard.object(forKey: "silencePauseMinutes")
        defer {
            UserDefaults.standard.set(previousSource, forKey: "defaultAudioSource")
            UserDefaults.standard.set(previousTimeout, forKey: "silencePauseMinutes")
        }
        coordinator.sourceSelection = .microphone
        coordinator.silencePauseMinutes = 30
        await coordinator.startRecording()
        check(coordinator.status == .recording, "mock recording starts")
        var notifications = 0
        let observation = coordinator.objectWillChange.sink { notifications += 1 }
        for _ in 0..<100_000 { microphone.onLevelUpdate?(0.4) }
        check(notifications == 0, "100000 audio callbacks enqueue no coordinator UI updates")
        coordinator.refreshRecordingActivity(at: ProcessInfo.processInfo.systemUptime + 1801)
        check(coordinator.isPaused && coordinator.silencePausePresented, "silence pauses and presents reminder")
        check(microphone.pauseCount == 1, "capture actually paused once")
        coordinator.refreshRecordingActivity(at: ProcessInfo.processInfo.systemUptime + 4000)
        check(microphone.pauseCount == 1 && coordinator.isPaused, "guard does not repeat or auto resume")
        coordinator.resumeRecording()
        coordinator.refreshRecordingActivity()
        check(coordinator.isRecording && !coordinator.silencePausePresented, "explicit resume starts a fresh window")
        coordinator.silencePauseMinutes = 0
        coordinator.refreshRecordingActivity(at: ProcessInfo.processInfo.systemUptime + 100_000)
        check(coordinator.isRecording, "disabled guard leaves recording running")
        coordinator.silencePauseMinutes = 60
        coordinator.refreshRecordingActivity(at: ProcessInfo.processInfo.systemUptime + 1801)
        check(coordinator.isRecording, "60 minute option does not pause at 30 minutes")
        coordinator.refreshRecordingActivity(at: ProcessInfo.processInfo.systemUptime + 3601)
        check(coordinator.isPaused, "60 minute option pauses at threshold")
        await coordinator.stopRecording()
        check(coordinator.status == .completed && !coordinator.silencePausePresented, "save works after automatic pause")
        let summaryURL = try repository.saveSummary("测试纪要", sessionID: session.id)
        let documentURL = try repository.saveFormattedDocument("测试文稿", sessionID: session.id)
        let trackedURLs = [repository.transcriptMarkdownURL(for: session.id),
            repository.sessionDirectory(for: session.id).appending(path: "逐字稿.json"),
            summaryURL, documentURL,
            repository.sessionDirectory(for: session.id).appending(path: ".minuteflow-session.json")]
        let oldDate = Date(timeIntervalSince1970: 946684800)
        for url in trackedURLs { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: url.path) }
        for _ in 0..<3 {
            coordinator.selectSession(session)
            coordinator.flushPendingEdits()
            coordinator.prepareNewRecording()
        }
        for url in trackedURLs {
            let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            check(date == oldDate, "view/switch/quit preserves modification date: \(url.lastPathComponent)")
        }
        _ = try repository.saveTranscript(segments, sessionID: session.id)
        _ = try repository.saveSummary("测试纪要", sessionID: session.id)
        _ = try repository.saveFormattedDocument("测试文稿", sessionID: session.id)
        for url in trackedURLs.prefix(4) {
            let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            check(date == oldDate, "identical save preserves modification date: \(url.lastPathComponent)")
        }
        coordinator.selectSession(session)
        coordinator.updateTranscriptSegment(id: segments[0].id, text: "立即退出也保存")
        coordinator.meetingTitle = "退出保存测试"
        coordinator.scheduleCurrentMeetingRename()
        coordinator.flushPendingEdits()
        check(try repository.loadTranscript(sessionID: session.id).first?.text == "立即退出也保存",
              "quit flush persists debounced transcript edit")
        check(repository.sessionDirectory(for: session.id).lastPathComponent == "退出保存测试",
              "quit flush persists pending meeting rename")
        withExtendedLifetime(observation) {}
        print("\(checks) regression checks passed; no real audio, credentials, or cloud APIs used.")
    }
}

private final class TestCapture: AudioCaptureService, @unchecked Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    var displayName: String { "Test" }
    var pauseCount = 0
    func start(outputURL: URL) async throws {}
    func pause() { pauseCount += 1 }
    func resume() {}
    func stop() async {}
}
private final class TestPermissions: PermissionManaging, @unchecked Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool { true }
    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState { .authorized }
    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState { .authorized }
    @MainActor func openSettings(for kind: PermissionKind) {}
}
@MainActor private final class TestLocation: MeetingLocationProviding {
    func captureLocation() async -> MeetingLocation? { nil }
}
