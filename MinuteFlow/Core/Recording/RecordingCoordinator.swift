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
    @Published private(set) var transcriptSegments: [TranscriptSegment] = []
    @Published private(set) var transcriptionActivity = "未开始转写"
    @Published private(set) var summaryMarkdown: String?
    @Published private(set) var isGeneratingSummary = false
    @Published var meetingTitle = ""
    @Published var userMessage: String?
    @Published var permissionIssue: PermissionIssue?

    var microphoneName: String { microphoneService.displayName }
    let modelSettings: ModelSettingsStore
    var isRecording: Bool { status == .recording }
    var isPaused: Bool { status == .paused }
    var canStart: Bool { !status.isActive }

    private static let sourceDefaultsKey = "defaultAudioSource"

    private let systemAudioService: AudioCaptureService
    private let microphoneService: AudioCaptureService
    private let repository: MeetingRepository
    private let permissionManager: PermissionManaging
    private let transcriptionService: RemoteRealtimeTranscriptionService
    private let summaryClient: RemoteSummaryClient
    private var systemAudioStarted = false
    private var microphoneStarted = false
    private var timer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    private var currentRunStartedAt: Date?
    private var transcriptionRunning = false

    init(
        systemAudioService: AudioCaptureService,
        microphoneService: AudioCaptureService,
        repository: MeetingRepository,
        permissionManager: PermissionManaging,
        modelSettings: ModelSettingsStore = ModelSettingsStore(),
        transcriptionService: RemoteRealtimeTranscriptionService = RemoteRealtimeTranscriptionService(),
        summaryClient: RemoteSummaryClient = RemoteSummaryClient()
    ) {
        self.systemAudioService = systemAudioService
        self.microphoneService = microphoneService
        self.repository = repository
        self.permissionManager = permissionManager
        self.modelSettings = modelSettings
        self.transcriptionService = transcriptionService
        self.summaryClient = summaryClient

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
        transcriptSegments = []
        summaryMarkdown = nil
        transcriptionActivity = "准备转写…"
        transcriptionRunning = false
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

            startTranscriptionIfConfigured()

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
                if transcriptionRunning {
                    _ = await transcriptionService.finish()
                    transcriptionRunning = false
                }
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
            if transcriptionRunning {
                _ = await transcriptionService.finish()
                transcriptionRunning = false
            }
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

        if transcriptionRunning {
            transcriptionActivity = "正在完成剩余片段…"
            let completed = await transcriptionService.finish()
            for segment in completed where !transcriptSegments.contains(where: { $0.id == segment.id }) {
                transcriptSegments.append(segment)
            }
            transcriptSegments.sort { $0.startTime < $1.startTime }
            transcriptionRunning = false
        }

        if var session = currentSession {
            session.endTime = Date()
            session.duration = elapsedTime
            session.recordingStatus = .completed
            session.updatedAt = Date()
            do {
                if !transcriptSegments.isEmpty {
                    session.transcriptFileURL = try repository.saveTranscript(
                        transcriptSegments.sorted { $0.startTime < $1.startTime },
                        sessionID: session.id
                    )
                }
                try repository.save(session)
                currentSession = session
                status = .completed
                userMessage = transcriptSegments.isEmpty
                    ? "录音已安全保存；本次没有生成逐字稿。"
                    : "录音和逐字稿已安全保存。"
                reloadRecentSessions()
                if modelSettings.automaticSummary && modelSettings.summaryIsConfigured {
                    await generateSummary()
                }
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

    func selectSession(_ session: MeetingSession) {
        guard !status.isActive else {
            userMessage = "录音进行中，暂时不能切换会议。"
            return
        }
        currentSession = session
        status = session.recordingStatus
        elapsedTime = session.duration
        transcriptSegments = (try? repository.loadTranscript(sessionID: session.id)) ?? []
        summaryMarkdown = try? repository.loadSummary(sessionID: session.id)
        transcriptionActivity = transcriptSegments.isEmpty ? "尚无逐字稿" : "已载入逐字稿"
    }

    func prepareNewRecording() {
        guard !status.isActive else {
            userMessage = "当前录音仍在进行，请先停止并保存。"
            return
        }
        currentSession = nil
        meetingTitle = ""
        transcriptSegments = []
        summaryMarkdown = nil
        elapsedTime = 0
        status = .idle
        transcriptionActivity = "未开始转写"
        userMessage = nil
    }

    func deleteSession(_ session: MeetingSession) {
        if status.isActive, currentSession?.id == session.id {
            userMessage = "请先停止当前录音，再删除这条会议记录。"
            return
        }
        do {
            try repository.deleteSession(id: session.id)
            if currentSession?.id == session.id {
                currentSession = nil
                transcriptSegments = []
                summaryMarkdown = nil
                elapsedTime = 0
                status = .idle
            }
            reloadRecentSessions()
            userMessage = "会议记录及其录音文件已删除。"
        } catch {
            userMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    func generateSummary() async {
        guard !transcriptSegments.isEmpty else {
            userMessage = "当前会议没有逐字稿，无法生成会议纪要。"
            return
        }
        guard
            modelSettings.summaryIsConfigured,
            let endpoint = modelSettings.resolvedSummaryEndpoint
        else {
            userMessage = "请先在设置 → 会议总结中配置 MiMo、DeepSeek 或 GLM 模型。"
            return
        }
        guard var session = currentSession else { return }

        isGeneratingSummary = true
        defer { isGeneratingSummary = false }
        do {
            let markdown = try await summaryClient.summarize(
                title: session.title,
                segments: transcriptSegments,
                configuration: SummaryConfiguration(
                    endpoint: endpoint,
                    model: modelSettings.summaryModel,
                    apiKey: modelSettings.summaryAPIKey,
                    prompt: modelSettings.summaryPrompt
                )
            )
            session.summaryFileURL = try repository.saveSummary(markdown, sessionID: session.id)
            session.updatedAt = Date()
            try repository.save(session)
            currentSession = session
            summaryMarkdown = markdown
            reloadRecentSessions()
            userMessage = "会议纪要已生成并保存在本地。"
        } catch {
            userMessage = "会议总结失败：\(error.localizedDescription)"
        }
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
        systemAudioService.onAudioBuffer = { [weak self] packet in
            self?.transcriptionService.append(packet)
        }
        microphoneService.onAudioBuffer = { [weak self] packet in
            self?.transcriptionService.append(packet)
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
        transcriptionService.onSegment = { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.transcriptSegments.append(segment)
                self.transcriptSegments.sort { $0.startTime < $1.startTime }
                self.persistCurrentTranscript()
            }
        }
        transcriptionService.onStatus = { [weak self] activity in
            Task { @MainActor [weak self] in self?.transcriptionActivity = activity }
        }
        transcriptionService.onError = { [weak self] error in
            let message = error.localizedDescription
            Task { @MainActor [weak self] in
                self?.transcriptionActivity = "转写异常，录音仍在继续"
                self?.userMessage = "转写失败：\(message)\n录音仍在继续，可在设置中检查模型配置。"
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

    private func startTranscriptionIfConfigured() {
        guard modelSettings.sttProvider != .disabled else {
            transcriptionActivity = "已关闭自动转写"
            return
        }
        guard
            modelSettings.sttIsConfigured,
            let endpoint = modelSettings.resolvedSTTEndpoint
        else {
            transcriptionActivity = "等待配置语音识别模型"
            userMessage = "录音会正常进行；请在设置 → 语音识别中填写 MiMo 或 GLM API Key 后启用自动转写。"
            return
        }

        var sources = Set<TranscriptSource>()
        if sourceSelection.systemAudioEnabled { sources.insert(.system) }
        if sourceSelection.microphoneEnabled { sources.insert(.microphone) }
        do {
            try transcriptionService.start(
                sources: sources,
                configuration: ASRConfiguration(
                    provider: modelSettings.sttProvider,
                    endpoint: endpoint,
                    model: modelSettings.resolvedSTTModel,
                    apiKey: modelSettings.sttAPIKey,
                    language: modelSettings.transcriptionLanguage
                )
            )
            transcriptionRunning = true
        } catch {
            transcriptionActivity = "转写启动失败"
            userMessage = "转写未能启动：\(error.localizedDescription)\n录音仍可正常进行。"
        }
    }

    private func persistCurrentTranscript() {
        guard var session = currentSession, !transcriptSegments.isEmpty else { return }
        do {
            session.transcriptFileURL = try repository.saveTranscript(
                transcriptSegments,
                sessionID: session.id
            )
            session.updatedAt = Date()
            try repository.save(session)
            currentSession = session
        } catch {
            userMessage = "逐字稿自动保存失败：\(error.localizedDescription)"
        }
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
