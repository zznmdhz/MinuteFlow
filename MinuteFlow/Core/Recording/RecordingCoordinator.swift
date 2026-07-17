import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published var sourceSelection: AudioSourceSelection {
        didSet { UserDefaults.standard.set(sourceSelection.rawValue, forKey: Self.sourceDefaultsKey) }
    }
    @Published private(set) var status: RecordingStatus = .idle
    @Published private(set) var elapsedTime: TimeInterval = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var currentSession: MeetingSession?
    @Published private(set) var recentSessions: [MeetingSession] = []
    @Published var meetingTitle = ""
    @Published var userMessage: String?
    @Published var permissionIssue: PermissionIssue?

    var microphoneName: String { microphoneService.displayName }
    var isRecording: Bool { status == .recording }
    var isPaused: Bool { status == .paused }
    var canStart: Bool { !status.isActive }

    private static let sourceDefaultsKey = "defaultAudioSource"

    private let systemAudioService: AudioCaptureService
    private let microphoneService: AudioCaptureService
    private let repository: MeetingRepository
    private let permissionManager: PermissionManaging
    private var systemAudioStarted = false
    private var microphoneStarted = false
    private var timer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    private var currentRunStartedAt: Date?

    init(
        systemAudioService: AudioCaptureService,
        microphoneService: AudioCaptureService,
        repository: MeetingRepository,
        permissionManager: PermissionManaging
    ) {
        self.systemAudioService = systemAudioService
        self.microphoneService = microphoneService
        self.repository = repository
        self.permissionManager = permissionManager

        if
            let savedValue = UserDefaults.standard.string(forKey: Self.sourceDefaultsKey),
            let savedSelection = AudioSourceSelection(rawValue: savedValue)
        {
            sourceSelection = savedSelection
        } else {
            sourceSelection = .both
        }

        configureCallbacks()
        reloadRecentSessions()
    }

    func startRecording() async {
        guard canStart else { return }

        status = .preparing
        userMessage = nil
        permissionIssue = nil
        elapsedTime = 0
        accumulatedDuration = 0
        systemLevel = 0
        microphoneLevel = 0
        systemAudioStarted = false
        microphoneStarted = false

        let title = resolvedMeetingTitle()
        var warnings: [String] = []

        do {
            var session = try repository.createSession(
                title: title,
                sourceSelection: sourceSelection
            )
            currentSession = session

            if sourceSelection.systemAudioEnabled, let url = session.systemAudioURL {
                if await permissionManager.requestPermission(for: .systemAudio) {
                    do {
                        try await systemAudioService.start(outputURL: url)
                        systemAudioStarted = true
                    } catch {
                        session.systemAudioURL = nil
                        warnings.append("系统声音未能启动：\(error.localizedDescription)")
                    }
                } else {
                    session.systemAudioURL = nil
                    permissionIssue = PermissionIssue(
                        kind: .systemAudio,
                        detail: "用于捕获腾讯会议、飞书、Zoom 或浏览器播放的声音。开启后通常需要重新启动应用。"
                    )
                    warnings.append("系统声音未录制：缺少屏幕与系统音频录制权限。")
                }
            }

            if sourceSelection.microphoneEnabled, let url = session.microphoneAudioURL {
                if await permissionManager.requestPermission(for: .microphone) {
                    do {
                        try await microphoneService.start(outputURL: url)
                        microphoneStarted = true
                    } catch {
                        session.microphoneAudioURL = nil
                        warnings.append("麦克风未能启动：\(error.localizedDescription)")
                    }
                } else {
                    session.microphoneAudioURL = nil
                    if permissionIssue == nil {
                        permissionIssue = PermissionIssue(
                            kind: .microphone,
                            detail: "用于单独录制你在会议中的发言。开启后重新开始录音即可。"
                        )
                    }
                    warnings.append("麦克风未录制：缺少麦克风权限。")
                }
            }

            guard systemAudioStarted || microphoneStarted else {
                session.recordingStatus = .failed
                session.updatedAt = Date()
                try? repository.save(session)
                currentSession = session
                status = .failed
                userMessage = warnings.joined(separator: "\n")
                return
            }

            session.recordingStatus = .recording
            session.updatedAt = Date()
            try repository.save(session)
            currentSession = session
            status = .recording
            currentRunStartedAt = Date()
            startTimer()

            if !warnings.isEmpty {
                userMessage = warnings.joined(separator: "\n") + "\n另一路录音仍在继续。"
            }
        } catch {
            await stopActiveServices()
            status = .failed
            userMessage = "无法创建会议录音：\(error.localizedDescription)"
        }
    }

    func pauseRecording() {
        guard status == .recording else { return }
        updateElapsedTime()
        accumulatedDuration = elapsedTime
        currentRunStartedAt = nil
        if systemAudioStarted { systemAudioService.pause() }
        if microphoneStarted { microphoneService.pause() }
        status = .paused
        updateSessionStatus(.paused)
    }

    func resumeRecording() {
        guard status == .paused else { return }
        if systemAudioStarted { systemAudioService.resume() }
        if microphoneStarted { microphoneService.resume() }
        currentRunStartedAt = Date()
        status = .recording
        updateSessionStatus(.recording)
    }

    func stopRecording() async {
        guard status == .recording || status == .paused else { return }
        updateElapsedTime()
        timer?.invalidate()
        timer = nil
        currentRunStartedAt = nil
        status = .saving
        updateSessionStatus(.saving)

        await stopActiveServices()

        if var session = currentSession {
            session.endTime = Date()
            session.duration = elapsedTime
            session.recordingStatus = .completed
            session.updatedAt = Date()
            do {
                try repository.save(session)
                currentSession = session
                status = .completed
                userMessage = "录音已安全保存。"
                reloadRecentSessions()
            } catch {
                currentSession = session
                status = .failed
                userMessage = "音频已停止，但会议信息保存失败：\(error.localizedDescription)"
            }
        } else {
            status = .completed
        }
    }

    func openPermissionSettings() {
        guard let permissionIssue else { return }
        permissionManager.openSettings(for: permissionIssue.kind)
    }

    func openCurrentSessionFolder() {
        guard let currentSession else { return }
        let directory = repository.sessionDirectory(for: currentSession.id)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func dismissMessage() {
        userMessage = nil
    }

    private func configureCallbacks() {
        systemAudioService.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in self?.systemLevel = level }
        }
        microphoneService.onLevelUpdate = { [weak self] level in
            Task { @MainActor [weak self] in self?.microphoneLevel = level }
        }
        systemAudioService.onError = { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.userMessage = "系统声音录制异常：\(message)\n麦克风录音会尽可能继续。"
            }
        }
        microphoneService.onError = { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.userMessage = "麦克风录制异常：\(message)\n系统声音录音会尽可能继续。"
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateElapsedTime() }
        }
    }

    private func updateElapsedTime() {
        guard let currentRunStartedAt else {
            elapsedTime = accumulatedDuration
            return
        }
        elapsedTime = accumulatedDuration + Date().timeIntervalSince(currentRunStartedAt)
    }

    private func stopActiveServices() async {
        if systemAudioStarted {
            await systemAudioService.stop()
            systemAudioStarted = false
        }
        if microphoneStarted {
            await microphoneService.stop()
            microphoneStarted = false
        }
        systemLevel = 0
        microphoneLevel = 0
    }

    private func updateSessionStatus(_ newStatus: RecordingStatus) {
        guard var session = currentSession else { return }
        session.recordingStatus = newStatus
        session.duration = elapsedTime
        session.updatedAt = Date()
        currentSession = session
        try? repository.save(session)
    }

    private func reloadRecentSessions() {
        recentSessions = (try? repository.loadRecentSessions()) ?? []
    }

    private func resolvedMeetingTitle() -> String {
        let trimmed = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return "未命名会议 \(Self.titleDateFormatter.string(from: Date()))"
    }

    private static let titleDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

