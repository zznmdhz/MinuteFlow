import AppKit
import Combine
import Foundation

@MainActor
final class RecordingCoordinator: ObservableObject {
    @Published var sourceSelection: AudioSourceSelection {
        didSet { UserDefaults.standard.set(sourceSelection.rawValue, forKey: Self.sourceDefaultsKey) }
    }
    @Published var recordMeetingLocation: Bool = UserDefaults.standard.object(forKey: "recordMeetingLocation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordMeetingLocation, forKey: "recordMeetingLocation") }
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
    @Published private(set) var formattedDocumentMarkdown: String?
    @Published private(set) var isGeneratingDocument = false
    @Published private(set) var speakerTurns: [SpeakerTurn] = []
    @Published private(set) var isAnalyzingSpeakers = false
    @Published private(set) var speakerAnalysisMessage = "尚未分析说话人"
    @Published private(set) var isPostTranscribing = false
    @Published private(set) var postTranscriptionProgress: Double = 0
    @Published private(set) var postTranscriptionMessage = ""
    @Published private(set) var isOrganizingHistoricalTitles = false
    @Published private(set) var historicalTitleProgress: Double = 0
    @Published private(set) var historicalTitleMessage = ""
    @Published var meetingTitle = ""
    @Published var userMessage: String?
    @Published var permissionIssue: PermissionIssue?
    @Published private(set) var microphonePermission: PermissionAuthorizationState = .notDetermined
    @Published private(set) var systemAudioPermission: PermissionAuthorizationState = .notDetermined

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
    private let postTranscriptionService: any PostRecordingTranscribing
    private let summaryClient: any SummaryClient
    private let documentFormattingClient: any DocumentFormattingClient
    private let speakerDiarizer: any SpeakerDiarizing
    private let audioMixer: any AudioMixing
    private let locationProvider: any MeetingLocationProviding
    private let recordingTimeline = RecordingTimelineBuilder()
    private var systemAudioStarted = false
    private var microphoneStarted = false
    private var timer: Timer?
    private var accumulatedDuration: TimeInterval = 0
    private var currentRunStartedAt: Date?
    private var transcriptionRunning = false
    private var summarySessionID: UUID?
    private var documentSessionID: UUID?
    private var speakerAnalysisSessionID: UUID?
    private var transcriptSaveTask: Task<Void, Never>?
    private var postTranscriptionTask: Task<Void, Never>?
    private var locationCaptureTask: Task<Void, Never>?
    private var settingsCancellables: Set<AnyCancellable> = []

    init(
        systemAudioService: AudioCaptureService,
        microphoneService: AudioCaptureService,
        repository: MeetingRepository,
        permissionManager: PermissionManaging,
        modelSettings: ModelSettingsStore = ModelSettingsStore(),
        transcriptionService: RemoteRealtimeTranscriptionService = RemoteRealtimeTranscriptionService(),
        postTranscriptionService: any PostRecordingTranscribing = PostRecordingTranscriptionService(),
        summaryClient: any SummaryClient = RemoteSummaryClient(),
        documentFormattingClient: any DocumentFormattingClient = RemoteDocumentFormattingClient(),
        speakerDiarizer: any SpeakerDiarizing = LocalSpeakerDiarizer(),
        audioMixer: any AudioMixing = AVFoundationOfflineAudioMixer(),
        locationProvider: any MeetingLocationProviding = MeetingLocationProvider()
    ) {
        self.systemAudioService = systemAudioService
        self.microphoneService = microphoneService
        self.repository = repository
        self.permissionManager = permissionManager
        self.modelSettings = modelSettings
        self.transcriptionService = transcriptionService
        self.postTranscriptionService = postTranscriptionService
        self.summaryClient = summaryClient
        self.documentFormattingClient = documentFormattingClient
        self.speakerDiarizer = speakerDiarizer
        self.audioMixer = audioMixer
        self.locationProvider = locationProvider

        if
            let savedValue = UserDefaults.standard.string(forKey: Self.sourceDefaultsKey),
            let savedSelection = AudioSourceSelection(rawValue: savedValue)
        {
            sourceSelection = savedSelection
        } else {
            sourceSelection = .both
        }

        configureCallbacks()
        observeRuntimeModelConfiguration()
        reloadRecentSessions()
        refreshPermissionStates()
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
        formattedDocumentMarkdown = nil
        speakerTurns = []
        speakerAnalysisMessage = "录音完成后分析说话人"
        transcriptionActivity = "准备转写…"
        transcriptionRunning = false
        systemAudioStarted = false
        microphoneStarted = false
        recordingTimeline.reset()

        let title = resolvedMeetingTitle()
        var warnings: [String] = []

        do {
            var session = try repository.createSession(
                title: title,
                sourceSelection: sourceSelection
            )
            currentSession = session
            beginLocationCapture(for: session.id)

            // Resolve all potentially interactive permission prompts before either
            // recorder starts. This prevents one source from running for several
            // seconds while the user is still answering the other source's prompt.
            var microphoneAllowed = true
            if sourceSelection.microphoneEnabled {
                microphoneAllowed = await permissionManager.requestPermission(for: .microphone)
                microphonePermission = microphoneAllowed ? .authorized : .denied
                if !microphoneAllowed {
                    session.microphoneAudioURL = nil
                    permissionIssue = PermissionIssue(
                        kind: .microphone,
                        detail: "用于单独录制你在会议中的发言。开启后重新开始录音即可。"
                    )
                    warnings.append("麦克风未录制：缺少麦克风权限。")
                }
            }

            recordingTimeline.beginActivePeriod(logicalStart: 0)

            if sourceSelection.systemAudioEnabled, let url = session.systemAudioURL {
                let passiveStatus = permissionManager.authorizationStatus(for: .systemAudio)
                if passiveStatus == .authorized {
                    do {
                        try await systemAudioService.start(outputURL: url)
                        systemAudioStarted = true
                        systemAudioPermission = .authorized
                    } catch {
                        session.systemAudioURL = nil
                        let failure = SystemAudioFailure(error: error)
                        if failure.isPermissionRelated {
                            systemAudioPermission = .denied
                            permissionIssue = PermissionIssue(kind: .systemAudio, detail: failure.recoverySuggestion)
                        }
                        warnings.append(failure.userMessage)
                    }
                } else {
                    let granted = await permissionManager.requestPermission(for: .systemAudio)
                    session.systemAudioURL = nil
                    permissionIssue = PermissionIssue(
                        kind: .systemAudio,
                        detail: granted
                            ? "权限已提交给 macOS。请完全退出 MinuteFlow 后重新打开，再开始录音。"
                            : "请在系统设置中允许当前这一个 MinuteFlow.app，然后完全退出并重新打开。"
                    )
                    systemAudioPermission = granted ? .restartRequired : .denied
                    warnings.append(granted
                        ? "系统声音权限已授予，但需要重新启动应用后生效。"
                        : "系统声音未录制：当前应用身份尚未获得权限。")
                }
            }

            if sourceSelection.microphoneEnabled, microphoneAllowed, let url = session.microphoneAudioURL {
                do {
                    try await microphoneService.start(outputURL: url)
                    microphoneStarted = true
                    microphonePermission = .authorized
                } catch {
                    session.microphoneAudioURL = nil
                    warnings.append("麦克风未能启动：\(error.localizedDescription)")
                }
            }

            guard systemAudioStarted || microphoneStarted else {
                recordingTimeline.endActivePeriod()
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
            startTranscriptionIfConfigured(timelineOffset: 0)

            if !warnings.isEmpty {
                userMessage = warnings.joined(separator: "\n") + "\n另一路录音仍在继续。"
            }
        } catch {
            await stopActiveServices()
            recordingTimeline.endActivePeriod()
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
        currentRunStartedAt = nil
        if systemAudioStarted { systemAudioService.pause() }
        if microphoneStarted { microphoneService.pause() }
        if transcriptionRunning {
            transcriptionService.splitCurrentUtterances(reason: .userPause)
        }
        let timelineDuration = recordingTimeline.endActivePeriod()
        accumulatedDuration = timelineDuration > 0 ? timelineDuration : elapsedTime
        elapsedTime = accumulatedDuration
        status = .paused
        updateSessionStatus(.paused)
    }

    func resumeRecording() {
        guard status == .paused else { return }
        recordingTimeline.beginActivePeriod(logicalStart: accumulatedDuration)
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
        let timelineDuration = recordingTimeline.endActivePeriod()
        if timelineDuration > 0 {
            elapsedTime = timelineDuration
            accumulatedDuration = timelineDuration
        }

        if transcriptionRunning {
            transcriptionActivity = "正在完成剩余片段…"
            let completed = await transcriptionService.finish()
            for segment in completed where !transcriptSegments.contains(where: { $0.id == segment.id }) {
                transcriptSegments.append(segment)
            }
            transcriptSegments.removeAll { !$0.isFinal }
            transcriptSegments.sort { $0.startTime < $1.startTime }
            transcriptionRunning = false
        }

        if var session = currentSession {
            session.endTime = Date()
            session.duration = elapsedTime
            session.recordingStatus = .completed
            if session.sourceSelection == .both {
                session.mixState = .queued
            }
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

                if session.sourceSelection == .both {
                    transcriptionActivity = "正在生成完整回放…"
                    session = await generateCompletePlayback(for: session)
                    try repository.save(session)
                    currentSession = session
                }

                transcriptionActivity = "正在检查音轨并分析说话人…"
                session = await inspectAudioAndAnalyzeSpeakers(for: session)
                try repository.save(session)
                currentSession = session

                session = await applyAutomaticTitleIfNeeded(to: session)
                currentSession = session

                status = .completed
                if session.mixState == .ready || session.mixState == .degraded {
                    userMessage = transcriptSegments.isEmpty
                        ? "原始分轨和完整回放已安全保存；本次没有生成逐字稿。"
                        : "原始分轨、完整回放和逐字稿已安全保存。"
                } else if session.sourceSelection == .both, session.mixState == .failed {
                    userMessage = "原始分轨已安全保存，但完整回放暂未生成。\n\(session.mixMessage ?? "可以继续播放原始分轨。")"
                } else {
                    userMessage = transcriptSegments.isEmpty
                        ? "录音已安全保存；本次没有生成逐字稿。"
                        : "录音和逐字稿已安全保存。"
                }
                if let warning = sourceHealthWarning(for: session) {
                    userMessage = (userMessage ?? "录音已保存。") + "\n" + warning
                }
                transcriptionActivity = transcriptSegments.isEmpty
                    ? "录音完成 · 尚无逐字稿"
                    : "转写与说话人时间轴已保存"
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

    func finishActiveWorkForTermination() async {
        while status == .preparing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if status == .recording || status == .paused {
            await stopRecording()
        }
        while status == .saving {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func openPermissionSettings() {
        guard let permissionIssue else { return }
        permissionManager.openSettings(for: permissionIssue.kind)
    }

    func openPermissionSettings(_ kind: PermissionKind) {
        permissionManager.openSettings(for: kind)
    }

    func refreshPermissionStates() {
        microphonePermission = permissionManager.authorizationStatus(for: .microphone)
        systemAudioPermission = permissionManager.authorizationStatus(for: .systemAudio)
    }

    func verifyPermissionStates() async {
        microphonePermission = await permissionManager.verifyPermission(for: .microphone)
        systemAudioPermission = await permissionManager.verifyPermission(for: .systemAudio)
    }

    func requestPermission(_ kind: PermissionKind) async {
        let granted = await permissionManager.requestPermission(for: kind)
        refreshPermissionStates()
        if kind == .systemAudio, granted, systemAudioPermission != .authorized {
            systemAudioPermission = .restartRequired
        }
        if !granted || permissionManager.authorizationStatus(for: kind) != .authorized {
            permissionIssue = PermissionIssue(
                kind: kind,
                detail: kind == .systemAudio
                    ? "开启后必须完全退出并重新打开 MinuteFlow，macOS 才会让当前应用使用录屏与系统音频权限。"
                    : "用于录制你的发言；开启后可以立即重新测试。"
            )
        }
    }

    func openCurrentSessionFolder() {
        guard let currentSession else { return }
        openSessionFolder(currentSession)
    }

    func openSessionFolder(_ session: MeetingSession) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.sessionDirectory(for: session.id)])
    }

    func revealTranscriptInFinder() {
        guard let id = currentSession?.id else { return }
        revealInFinder(repository.transcriptMarkdownURL(for: id), sessionID: id)
    }

    func revealSummaryInFinder() {
        guard let id = currentSession?.id else { return }
        revealInFinder(repository.summaryMarkdownURL(for: id), sessionID: id)
    }

    func revealFormattedDocumentInFinder() {
        guard let id = currentSession?.id else { return }
        revealInFinder(repository.formattedDocumentURL(for: id), sessionID: id)
    }

    func openAudioFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func revealInFinder(_ url: URL, sessionID: UUID) {
        let target = FileManager.default.fileExists(atPath: url.path)
            ? url
            : repository.sessionDirectory(for: sessionID)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func retryCompletePlayback(sessionID: UUID) async {
        guard !status.isActive else {
            userMessage = "请先完成当前录音，再重新生成完整回放。"
            return
        }
        guard var session = (currentSession?.id == sessionID ? currentSession : nil)
            ?? recentSessions.first(where: { $0.id == sessionID }) else { return }

        let sourceURLs: [(TranscriptSource, URL)] = [
            session.systemAudioURL.map { (.system, $0) },
            session.microphoneAudioURL.map { (.microphone, $0) }
        ].compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0.1.path) }
        guard !sourceURLs.isEmpty else {
            userMessage = "找不到可读取的原始分轨，无法重新生成完整回放。"
            return
        }

        let manifest = (try? Data(contentsOf: repository.mixManifestURL(for: session.id)))
            .flatMap { try? JSONDecoder().decode(AudioMixTimelineManifest.self, from: $0) }
        let epochsBySource = Dictionary(uniqueKeysWithValues: (manifest?.tracks ?? []).map { ($0.source, $0.epochs) })
        let inputs = sourceURLs.map { source, url in
            AudioMixInput(source: source, url: url, epochs: epochsBySource[source] ?? [])
        }

        session.mixState = .processing
        session.mixMessage = manifest == nil
            ? "正在按原始文件起点近似生成完整回放。"
            : "正在按录音时间轴重新生成完整回放。"
        session.mixUpdatedAt = Date()
        try? repository.save(session)
        if currentSession?.id == sessionID { currentSession = session }

        do {
            let result = try await audioMixer.mix(AudioMixRequest(
                inputs: inputs,
                outputURL: repository.mixedAudioURL(for: session.id),
                expectedDuration: session.duration
            ))
            session.mixedAudioURL = result.outputURL
            session.mixState = result.degraded ? .degraded : .ready
            session.mixMessage = result.degraded
                ? "完整回放仅包含成功录制的声音来源；原始分轨均已保留。"
                : "完整回放已重新生成。"
            userMessage = "完整回放已重新生成。"
        } catch {
            session.mixedAudioURL = nil
            session.mixState = .failed
            session.mixMessage = "重新生成失败：\(error.localizedDescription) 原始分轨未受影响。"
            userMessage = session.mixMessage
        }
        session.mixUpdatedAt = Date()
        session.updatedAt = Date()
        try? repository.save(session)
        if currentSession?.id == sessionID { currentSession = session }
        reloadRecentSessions()
    }

    func renameCurrentMeeting() {
        guard let session = currentSession, !status.isActive else { return }
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        renameSession(session, to: title)
    }

    func renameSession(_ original: MeetingSession, to newTitle: String) {
        guard !status.isActive || currentSession?.id != original.id else {
            userMessage = "录音进行中，结束保存后才能重命名这条会议。"
            return
        }
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != original.title else { return }
        do {
            var session = try repository.renameSession(original, to: String(title.prefix(100)))
            session.titleWasAutomaticallyGenerated = false
            try repository.save(session)
            if currentSession?.id == session.id {
                currentSession = session
                meetingTitle = session.title
            }
            reloadRecentSessions()
            userMessage = "会议和对应文件夹已同步重命名。"
        } catch {
            userMessage = "会议名称保存失败：\(error.localizedDescription)"
        }
    }

    func organizeHistoricalMeetingTitles() async {
        guard !status.isActive, !isOrganizingHistoricalTitles else { return }
        guard
            modelSettings.summaryIsConfigured,
            let endpoint = modelSettings.resolvedSummaryEndpoint
        else {
            userMessage = "请先在设置 → AI 服务中配置并测试文本模型。"
            return
        }

        let candidates = recentSessions.filter { $0.title.hasPrefix("未命名会议 ") }
        guard !candidates.isEmpty else {
            userMessage = "现有会议都已经有主题。"
            return
        }

        isOrganizingHistoricalTitles = true
        historicalTitleProgress = 0
        var renamedCount = 0
        var skippedCount = 0
        var failedCount = 0
        defer { isOrganizingHistoricalTitles = false }

        for (index, original) in candidates.enumerated() {
            historicalTitleMessage = "正在整理 \(index + 1)/\(candidates.count)：\(original.title)"
            var evidence = (try? repository.loadTranscript(sessionID: original.id))?.filter(\.isFinal) ?? []
            if evidence.isEmpty,
               let summary = try? repository.loadSummary(sessionID: original.id),
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                evidence = [TranscriptSegment(
                    startTime: 0,
                    endTime: original.duration,
                    text: summary,
                    source: .mixed,
                    isFinal: true
                )]
            }
            guard !evidence.isEmpty else {
                skippedCount += 1
                historicalTitleProgress = Double(index + 1) / Double(candidates.count)
                continue
            }

            do {
                let response = try await summaryClient.summarize(
                    title: original.title,
                    segments: Self.representativeTitleEvidence(evidence),
                    configuration: SummaryConfiguration(
                        endpoint: endpoint,
                        model: modelSettings.summaryModel,
                        apiKey: modelSettings.activeAPIKey,
                        prompt: "请只输出一个准确、具体的中文会议主题，不要解释、不要 Markdown、不要日期。长度 6 到 20 个汉字，必须基于内容，不得编造。"
                    )
                )
                guard let title = Self.cleanedAutomaticTitle(response) else {
                    failedCount += 1
                    historicalTitleProgress = Double(index + 1) / Double(candidates.count)
                    continue
                }
                var renamed = try repository.renameSession(original, to: title)
                renamed.titleWasAutomaticallyGenerated = true
                try repository.save(renamed)
                if currentSession?.id == renamed.id {
                    currentSession = renamed
                    meetingTitle = renamed.title
                }
                renamedCount += 1
            } catch {
                failedCount += 1
            }
            historicalTitleProgress = Double(index + 1) / Double(candidates.count)
        }

        reloadRecentSessions()
        historicalTitleMessage = "整理完成：已命名 \(renamedCount) 场，缺少文字依据 \(skippedCount) 场，失败 \(failedCount) 场。"
        userMessage = historicalTitleMessage
    }

    func selectSession(_ session: MeetingSession) {
        guard !isPostTranscribing else {
            userMessage = "正在事后转写当前会议；完成或取消后再切换会议。"
            return
        }
        guard !status.isActive else {
            userMessage = "录音进行中，暂时不能切换会议。"
            return
        }
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        persistCurrentTranscript()
        currentSession = session
        meetingTitle = session.title
        status = session.recordingStatus.isActive ? .interrupted : session.recordingStatus
        elapsedTime = session.duration
        transcriptSegments = (try? repository.loadTranscript(sessionID: session.id)) ?? []
        summaryMarkdown = try? repository.loadSummary(sessionID: session.id)
        formattedDocumentMarkdown = try? repository.loadFormattedDocument(sessionID: session.id)
        if let diarization = try? repository.loadDiarization(sessionID: session.id) {
            speakerTurns = diarization.turns
            speakerAnalysisMessage = "已识别 \(diarization.speakerCount) 位说话人 · 本地分析"
        } else {
            speakerTurns = []
            speakerAnalysisMessage = "尚未分析说话人"
        }
        transcriptionActivity = transcriptSegments.isEmpty ? "尚无逐字稿" : "已载入逐字稿"
        if speakerTurns.isEmpty, transcriptSegments.contains(where: \.isFinal) {
            Task { [weak self] in
                await self?.analyzeCurrentMeetingSpeakers()
            }
        }
    }

    func prepareNewRecording() {
        guard !isPostTranscribing else {
            userMessage = "正在事后转写当前会议；完成或取消后再新建录音。"
            return
        }
        guard !status.isActive else {
            userMessage = "当前录音仍在进行，请先停止并保存。"
            return
        }
        transcriptSaveTask?.cancel()
        transcriptSaveTask = nil
        persistCurrentTranscript()
        currentSession = nil
        meetingTitle = ""
        transcriptSegments = []
        summaryMarkdown = nil
        formattedDocumentMarkdown = nil
        speakerTurns = []
        speakerAnalysisMessage = "尚未分析说话人"
        elapsedTime = 0
        status = .idle
        transcriptionActivity = "未开始转写"
        userMessage = nil
    }

    var canPostTranscribeCurrentMeeting: Bool {
        guard
            !status.isActive,
            !isPostTranscribing,
            let session = currentSession,
            let (_, source) = postTranscriptionAudio(for: session),
            modelSettings.asrIsConfigured
        else { return false }
        if (session.postTranscriptionCompletedDuration ?? 0) >= max(0, session.duration - 1) {
            return false
        }
        let completedTime = transcriptSegments
            .filter { $0.isFinal && $0.source == source }
            .map(\.endTime)
            .max() ?? 0
        return completedTime < max(0, session.duration - 1)
    }

    var shouldOfferPostTranscription: Bool {
        guard
            !status.isActive,
            let session = currentSession,
            let (_, source) = postTranscriptionAudio(for: session)
        else { return false }
        if (session.postTranscriptionCompletedDuration ?? 0) >= max(0, session.duration - 1) {
            return false
        }
        let completedTime = transcriptSegments
            .filter { $0.isFinal && $0.source == source }
            .map(\.endTime)
            .max() ?? 0
        return completedTime < max(0, session.duration - 1)
    }

    var postTranscriptionButtonTitle: String {
        if transcriptSegments.isEmpty { return "转写这段录音" }
        return transcriptSegments.contains(where: { $0.source == .mixed })
            ? "继续事后转写"
            : "补全整段录音"
    }

    func startPostRecordingTranscription() {
        guard !isPostTranscribing else { return }
        guard
            modelSettings.asrIsConfigured,
            let endpoint = modelSettings.resolvedASREndpoint
        else {
            userMessage = "请先在设置 → AI 服务中配置并测试语音识别模型。"
            return
        }
        guard
            let session = currentSession,
            let (audioURL, source) = postTranscriptionAudio(for: session)
        else {
            userMessage = PostTranscriptionError.noSavedAudio.localizedDescription
            return
        }

        let requestSessionID = session.id
        let resumeTime = transcriptSegments
            .filter { $0.isFinal && $0.source == source }
            .map(\.endTime)
            .max() ?? 0
        let configuration = ASRConfiguration(
            transport: modelSettings.detectedASRTransport,
            endpoint: endpoint,
            model: modelSettings.asrModel,
            apiKey: modelSettings.activeAPIKey,
            language: modelSettings.transcriptionLanguage
        )

        isPostTranscribing = true
        postTranscriptionProgress = session.duration > 0 ? min(1, resumeTime / session.duration) : 0
        postTranscriptionMessage = resumeTime > 0
            ? "从 \(DurationFormatter.string(from: resumeTime)) 继续转写…"
            : "正在分析录音并按说话停顿分段…"
        userMessage = nil

        postTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.postTranscriptionService.transcribe(
                    audioURL: audioURL,
                    sessionID: requestSessionID,
                    source: source,
                    startingAt: resumeTime,
                    configuration: configuration,
                    maximumChunkDuration: self.modelSettings.maximumChunkDuration,
                    onSegment: { [weak self] segment in
                        Task { @MainActor [weak self] in
                            guard
                                let self,
                                self.currentSession?.id == requestSessionID,
                                !self.transcriptSegments.contains(where: { $0.id == segment.id })
                            else { return }
                            self.transcriptSegments.append(segment)
                            self.transcriptSegments.sort { $0.startTime < $1.startTime }
                            self.persistCurrentTranscript()
                        }
                    },
                    onProgress: { [weak self] progress in
                        Task { @MainActor [weak self] in
                            guard self?.currentSession?.id == requestSessionID else { return }
                            self?.postTranscriptionProgress = progress.fraction
                            self?.postTranscriptionMessage =
                                "已转写 \(progress.completedChunks)/\(progress.totalChunks) 段 · \(DurationFormatter.string(from: progress.completedTime))"
                        }
                    }
                )
                await Task.yield()
                guard self.currentSession?.id == requestSessionID else { return }
                self.persistCurrentTranscript()
                if var updated = self.currentSession {
                    updated.postTranscriptionCompletedAt = Date()
                    updated.postTranscriptionCompletedDuration = updated.duration
                    updated = await self.inspectAudioAndAnalyzeSpeakers(for: updated)
                    try self.repository.save(updated)
                    self.currentSession = updated
                }
                self.postTranscriptionProgress = 1
                self.postTranscriptionMessage = "整段录音转写完成"
                self.transcriptionActivity = "事后转写与说话人时间轴已保存"
                self.userMessage = "事后转写完成；逐字稿已分段保存，并已生成说话人时间轴。"
                self.reloadRecentSessions()
            } catch is CancellationError {
                self.postTranscriptionMessage = "已取消；完成的片段已经保存，下次可继续"
                self.userMessage = "事后转写已取消；已完成的逐字稿不会丢失。"
            } catch {
                self.postTranscriptionMessage = "转写中断；完成的片段已经保存"
                self.userMessage = "事后转写未完成：\(error.localizedDescription)\n已完成的片段已保存，修复配置或网络后可继续。"
            }
            self.isPostTranscribing = false
            self.postTranscriptionTask = nil
        }
    }

    func cancelPostRecordingTranscription() {
        postTranscriptionTask?.cancel()
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
                formattedDocumentMarkdown = nil
                speakerTurns = []
                speakerAnalysisMessage = "尚未分析说话人"
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
        let finalSegments = transcriptSegments.filter(\.isFinal)
        guard !finalSegments.isEmpty else {
            userMessage = "当前会议没有逐字稿，无法生成会议纪要。"
            return
        }
        guard
            modelSettings.summaryIsConfigured,
            let endpoint = modelSettings.resolvedSummaryEndpoint
        else {
            userMessage = "请先在设置 → AI 服务中配置并测试总结模型。"
            return
        }
        guard var session = currentSession else { return }
        let requestSessionID = session.id
        guard summarySessionID != requestSessionID else {
            userMessage = "这条会议的纪要正在生成，请稍候。"
            return
        }

        summarySessionID = requestSessionID
        isGeneratingSummary = true
        defer {
            if summarySessionID == requestSessionID {
                summarySessionID = nil
                isGeneratingSummary = false
            }
        }
        do {
            let markdown = try await summaryClient.summarize(
                title: session.title,
                segments: finalSegments,
                configuration: SummaryConfiguration(
                    endpoint: endpoint,
                    model: modelSettings.summaryModel,
                    apiKey: modelSettings.activeAPIKey,
                    prompt: modelSettings.summaryPrompt
                )
            )
            session.summaryFileURL = try repository.saveSummary(markdown, sessionID: session.id)
            session.updatedAt = Date()
            try repository.save(session)
            if currentSession?.id == requestSessionID, !status.isActive {
                currentSession = session
                summaryMarkdown = markdown
                userMessage = "会议纪要已生成并保存在本地。"
            }
            reloadRecentSessions()
        } catch {
            if currentSession?.id == requestSessionID {
                userMessage = "会议总结失败：\(error.localizedDescription)"
            }
        }
    }

    func generateFormattedDocument() async {
        let finalSegments = transcriptSegments.filter(\.isFinal)
        guard !finalSegments.isEmpty else {
            userMessage = "当前会议没有逐字稿，无法整理文稿。"
            return
        }
        guard
            modelSettings.summaryIsConfigured,
            let endpoint = modelSettings.resolvedSummaryEndpoint
        else {
            userMessage = "AI 整理文稿使用同一个总结模型，请先在设置 → AI 服务中完成配置。"
            return
        }
        guard var session = currentSession else { return }
        let requestSessionID = session.id
        guard documentSessionID != requestSessionID else {
            userMessage = "这条会议的 AI 文稿正在生成，请稍候。"
            return
        }

        documentSessionID = requestSessionID
        isGeneratingDocument = true
        defer {
            if documentSessionID == requestSessionID {
                documentSessionID = nil
                isGeneratingDocument = false
            }
        }

        do {
            let markdown = try await documentFormattingClient.format(
                title: session.title,
                segments: finalSegments,
                configuration: DocumentFormattingConfiguration(
                    endpoint: endpoint,
                    model: modelSettings.summaryModel,
                    apiKey: modelSettings.activeAPIKey
                )
            )
            session.formattedDocumentFileURL = try repository.saveFormattedDocument(
                markdown,
                sessionID: session.id
            )
            session.updatedAt = Date()
            try repository.save(session)
            if currentSession?.id == requestSessionID, !status.isActive {
                currentSession = session
                formattedDocumentMarkdown = markdown
                userMessage = "AI 文稿已排版并保存为 Markdown 文档。"
            }
            reloadRecentSessions()
        } catch {
            if currentSession?.id == requestSessionID {
                userMessage = "AI 文稿整理失败：\(error.localizedDescription)"
            }
        }
    }

    func updateTranscriptSegment(id: UUID, text: String) {
        guard let index = transcriptSegments.firstIndex(where: { $0.id == id }) else { return }
        if transcriptSegments[index].originalText == nil {
            transcriptSegments[index].originalText = transcriptSegments[index].text
        }
        transcriptSegments[index].text = text
        transcriptSegments[index].normalizedText = nil
        scheduleTranscriptSave()
    }

    func restoreOriginalTranscriptSegment(id: UUID) {
        guard
            let index = transcriptSegments.firstIndex(where: { $0.id == id }),
            let original = transcriptSegments[index].originalText
        else { return }
        transcriptSegments[index].text = original
        transcriptSegments[index].normalizedText = nil
        persistCurrentTranscript()
    }

    func normalizeTranscript() {
        guard !transcriptSegments.isEmpty else { return }
        for index in transcriptSegments.indices {
            transcriptSegments[index].normalizedText = TranscriptNormalizer.normalize(transcriptSegments[index].text)
        }
        persistCurrentTranscript()
        userMessage = "已在本地完成空格、标点和断句校正；没有调用 AI，原始识别结果仍保留。"
    }

    func analyzeCurrentMeetingSpeakers() async {
        guard !status.isActive, let session = currentSession else {
            userMessage = "请先停止并保存录音，再分析说话人。"
            return
        }
        let requestSessionID = session.id
        guard speakerAnalysisSessionID != requestSessionID else { return }
        speakerAnalysisSessionID = requestSessionID
        isAnalyzingSpeakers = true
        speakerAnalysisMessage = "正在本地分析声纹与时间轴…"
        defer {
            if speakerAnalysisSessionID == requestSessionID {
                speakerAnalysisSessionID = nil
                isAnalyzingSpeakers = false
            }
        }
        let updated = await inspectAudioAndAnalyzeSpeakers(for: session)
        do {
            try repository.save(updated)
            if currentSession?.id == requestSessionID {
                currentSession = updated
                userMessage = sourceHealthWarning(for: updated)
                    ?? "说话人时间轴已重新生成并保存在本地。"
            }
            reloadRecentSessions()
        } catch {
            userMessage = "说话人分析结果保存失败：\(error.localizedDescription)"
        }
    }

    func speakerDisplayName(for speakerID: String) -> String {
        if let name = currentSession?.speakerNames?[speakerID], !name.isEmpty { return name }
        let number = speakerID.split(separator: "-").last.map(String.init) ?? speakerID
        return "说话人 \(number)"
    }

    func renameSpeaker(_ speakerID: String, to rawName: String) {
        guard var session = currentSession else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var names = session.speakerNames ?? [:]
        names[speakerID] = String(name.prefix(40))
        session.speakerNames = names
        session.updatedAt = Date()
        do {
            try repository.save(session)
            currentSession = session
            reloadRecentSessions()
        } catch {
            userMessage = "说话人名称保存失败：\(error.localizedDescription)"
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
            self?.recordingTimeline.record(packet)
            self?.transcriptionService.append(packet)
        }
        microphoneService.onAudioBuffer = { [weak self] packet in
            self?.recordingTimeline.record(packet)
            self?.transcriptionService.append(packet)
        }
        systemAudioService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeCaptureFailure(source: .system, error: error)
            }
        }
        microphoneService.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                await self?.handleRuntimeCaptureFailure(source: .microphone, error: error)
            }
        }
        transcriptionService.onSegment = { [weak self] segment in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.transcriptSegments.firstIndex(where: { $0.id == segment.id }) {
                    self.transcriptSegments[index] = segment
                } else {
                    self.transcriptSegments.append(segment)
                }
                self.transcriptSegments.sort { $0.startTime < $1.startTime }
                self.persistCurrentTranscript()
            }
        }
        transcriptionService.onPreview = { [weak self] preview in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let index = self.transcriptSegments.firstIndex(where: { $0.id == preview.id }) {
                    guard !self.transcriptSegments[index].isFinal else { return }
                    self.transcriptSegments[index] = preview
                } else {
                    self.transcriptSegments.append(preview)
                }
                self.transcriptSegments.sort { $0.startTime < $1.startTime }
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

    private func handleRuntimeCaptureFailure(source: TranscriptSource, error: any Error) async {
        guard status == .recording || status == .paused else { return }

        let stoppedAt = DurationFormatter.string(from: elapsedTime)
        switch source {
        case .system:
            guard systemAudioStarted else { return }
            await systemAudioService.stop()
            systemAudioStarted = false
            systemLevel = 0
            if transcriptionRunning {
                transcriptionService.splitCurrentUtterances(reason: .sourceInterrupted, sources: [.system])
            }
        case .microphone:
            guard microphoneStarted else { return }
            await microphoneService.stop()
            microphoneStarted = false
            microphoneLevel = 0
            if transcriptionRunning {
                transcriptionService.splitCurrentUtterances(reason: .sourceInterrupted, sources: [.microphone])
            }
        case .mixed:
            return
        }

        if !systemAudioStarted && !microphoneStarted {
            await stopRecording()
            userMessage = "所有录音来源均已在 \(stoppedAt) 中断，现有音频和逐字稿已保存。最后错误：\(error.localizedDescription)"
            return
        }

        if source == .system {
            let failure = SystemAudioFailure(error: error)
            userMessage = "系统声音已在 \(stoppedAt) 停止；麦克风仍在继续。\n\(failure.userMessage) \(failure.recoverySuggestion)"
        } else {
            userMessage = "麦克风已在 \(stoppedAt) 停止；系统声音仍在继续。\n\(error.localizedDescription)"
        }
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

    private func startTranscriptionIfConfigured(timelineOffset: TimeInterval = 0) {
        guard modelSettings.asrEnabled else {
            transcriptionActivity = "已关闭自动转写"
            return
        }
        guard
            modelSettings.asrIsConfigured,
            let endpoint = modelSettings.resolvedASREndpoint
        else {
            transcriptionActivity = "等待配置语音识别模型"
            userMessage = "录音会正常进行；请在设置 → AI 服务中填写 Base URL、Token 和 ASR 模型后启用自动转写。"
            return
        }

        var sources = Set<TranscriptSource>()
        if systemAudioStarted || microphoneStarted {
            if systemAudioStarted { sources.insert(.system) }
            if microphoneStarted { sources.insert(.microphone) }
        } else {
            if sourceSelection.systemAudioEnabled { sources.insert(.system) }
            if sourceSelection.microphoneEnabled { sources.insert(.microphone) }
        }
        do {
            try transcriptionService.start(
                sessionID: currentSession?.id ?? UUID(),
                sources: sources,
                configuration: ASRConfiguration(
                    transport: modelSettings.detectedASRTransport,
                    endpoint: endpoint,
                    model: modelSettings.asrModel,
                    apiKey: modelSettings.activeAPIKey,
                    language: modelSettings.transcriptionLanguage
                ),
                maximumChunkDuration: modelSettings.maximumChunkDuration,
                timelineOffset: timelineOffset
            )
            transcriptionRunning = true
        } catch {
            transcriptionActivity = "转写启动失败"
            userMessage = "转写未能启动：\(error.localizedDescription)\n录音仍可正常进行。"
        }
    }

    func activateCurrentASRConfiguration() {
        guard status == .recording || status == .paused else { return }
        updateElapsedTime()
        if transcriptionRunning {
            transcriptionService.abortForReconfiguration()
            transcriptionRunning = false
        }
        guard modelSettings.asrIsConfigured else {
            transcriptionActivity = "语音识别配置尚未生效"
            return
        }
        let offset = elapsedTime
        startTranscriptionIfConfigured(timelineOffset: offset)
        if transcriptionRunning {
            userMessage = offset > 0
                ? "新的语音识别配置已生效，将从 \(DurationFormatter.string(from: offset)) 开始实时转写；之前的部分可在录音结束后补齐。"
                : "新的语音识别配置已生效。"
        }
    }

    private func observeRuntimeModelConfiguration() {
        modelSettings.$runtimeConfigurationRevision
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.activateCurrentASRConfiguration()
            }
            .store(in: &settingsCancellables)
    }

    private func postTranscriptionAudio(
        for session: MeetingSession
    ) -> (URL, TranscriptSource)? {
        let candidates: [(URL?, TranscriptSource)] = [
            (session.mixedAudioURL, .mixed),
            (session.microphoneAudioURL, .microphone),
            (session.systemAudioURL, .system)
        ]
        for (optionalURL, source) in candidates {
            guard
                let url = optionalURL,
                FileManager.default.fileExists(atPath: url.path),
                ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0) > 0
            else { continue }
            return (url, source)
        }
        return nil
    }

    private func persistCurrentTranscript() {
        let finalSegments = transcriptSegments.filter(\.isFinal)
        guard var session = currentSession, !finalSegments.isEmpty else { return }
        do {
            session.transcriptFileURL = try repository.saveTranscript(
                finalSegments,
                sessionID: session.id
            )
            session.updatedAt = Date()
            try repository.save(session)
            currentSession = session
        } catch {
            userMessage = "逐字稿自动保存失败：\(error.localizedDescription)"
        }
    }

    private func scheduleTranscriptSave() {
        transcriptSaveTask?.cancel()
        transcriptSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.persistCurrentTranscript()
        }
    }

    private func inspectAudioAndAnalyzeSpeakers(for original: MeetingSession) async -> MeetingSession {
        var session = original
        var audible: [TranscriptSource: URL] = [:]
        var silent: [TranscriptSource] = []
        let rawSources: [(TranscriptSource, URL?)] = [
            (.system, session.systemAudioURL),
            (.microphone, session.microphoneAudioURL)
        ]
        for (source, optionalURL) in rawSources {
            guard let url = optionalURL, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let report = await AudioSignalInspector.inspect(url), report.hasAudibleSignal {
                audible[source] = url
            } else {
                silent.append(source)
            }
        }
        session.silentSources = silent.isEmpty ? nil : silent

        guard !transcriptSegments.filter(\.isFinal).isEmpty else {
            speakerTurns = []
            speakerAnalysisMessage = "没有逐字稿，暂不生成说话人时间轴"
            return session
        }

        let analysisURL: URL?
        if audible[.system] != nil,
           audible[.microphone] != nil,
           let mixed = session.mixedAudioURL,
           FileManager.default.fileExists(atPath: mixed.path) {
            analysisURL = mixed
        } else {
            analysisURL = audible[.microphone] ?? audible[.system]
        }
        guard let analysisURL else {
            speakerTurns = []
            speakerAnalysisMessage = "音轨没有足够信号，无法分析说话人"
            return session
        }

        do {
            let result = try await speakerDiarizer.analyze(audioURL: analysisURL)
            session.diarizationFileURL = try repository.saveDiarization(result, sessionID: session.id)
            var names = session.speakerNames ?? [:]
            for number in 1...max(1, result.speakerCount) {
                let id = "speaker-\(number)"
                if names[id] == nil { names[id] = "说话人 \(number)" }
            }
            session.speakerNames = names
            let aligned = TranscriptSpeakerAligner.align(segments: transcriptSegments, with: result)
            if !aligned.isEmpty {
                transcriptSegments = aligned
                session.transcriptFileURL = try repository.saveTranscript(aligned, sessionID: session.id)
            }
            speakerTurns = result.turns
            speakerAnalysisMessage = "已识别 \(result.speakerCount) 位说话人 · 本地分析"
        } catch {
            speakerTurns = []
            speakerAnalysisMessage = "说话人分析未完成：\(error.localizedDescription)"
        }
        session.updatedAt = Date()
        return session
    }

    private func sourceHealthWarning(for session: MeetingSession) -> String? {
        guard let silentSources = session.silentSources, !silentSources.isEmpty else { return nil }
        let names = silentSources.map(\.title).joined(separator: "、")
        return "注意：\(names)整段没有检测到有效声音。若对方声音来自电脑，请检查会议应用输出和系统录音来源。"
    }

    private func generateCompletePlayback(for originalSession: MeetingSession) async -> MeetingSession {
        var session = originalSession
        let sourceURLs: [(TranscriptSource, URL)] = [
            session.systemAudioURL.map { (.system, $0) },
            session.microphoneAudioURL.map { (.microphone, $0) }
        ].compactMap { $0 }
        .filter { FileManager.default.fileExists(atPath: $0.1.path) }

        guard !sourceURLs.isEmpty else {
            session.mixedAudioURL = nil
            session.mixState = .failed
            session.mixMessage = "没有找到可读取的原始分轨。"
            session.mixUpdatedAt = Date()
            return session
        }

        let sessionDirectory = repository.sessionDirectory(for: session.id)
        let relativePaths = Dictionary(uniqueKeysWithValues: sourceURLs.map { source, url in
            let prefix = sessionDirectory.path.hasSuffix("/") ? sessionDirectory.path : sessionDirectory.path + "/"
            let path = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            return (source, path)
        })
        let manifest = recordingTimeline.manifest(
            logicalDuration: session.duration,
            relativePaths: relativePaths,
            channelCounts: [.system: 2, .microphone: 1]
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: repository.mixManifestURL(for: session.id), options: .atomic)

            let epochsBySource = Dictionary(uniqueKeysWithValues: manifest.tracks.map { ($0.source, $0.epochs) })
            let inputs = sourceURLs.map { source, url in
                AudioMixInput(source: source, url: url, epochs: epochsBySource[source] ?? [])
            }
            session.mixState = .processing
            session.mixMessage = "正在从原始分轨生成完整回放。"
            session.mixUpdatedAt = Date()
            try repository.save(session)

            let result = try await audioMixer.mix(AudioMixRequest(
                inputs: inputs,
                outputURL: repository.mixedAudioURL(for: session.id),
                expectedDuration: session.duration
            ))
            session.mixedAudioURL = result.outputURL
            session.mixState = result.degraded ? .degraded : .ready
            session.mixMessage = result.degraded
                ? "完整回放仅包含成功录制的声音来源；原始分轨均已保留。"
                : "系统声音与麦克风已按录音时间轴合成为完整回放。"
            if !result.warnings.isEmpty {
                session.mixMessage = ([session.mixMessage].compactMap { $0 } + result.warnings).joined(separator: " ")
            }
            session.mixUpdatedAt = Date()
        } catch {
            session.mixedAudioURL = nil
            session.mixState = .failed
            session.mixMessage = "完整回放生成失败：\(error.localizedDescription) 原始分轨未受影响。"
            session.mixUpdatedAt = Date()
        }
        return session
    }

    private func beginLocationCapture(for sessionID: UUID) {
        locationCaptureTask?.cancel()
        guard recordMeetingLocation else { return }
        locationCaptureTask = Task { @MainActor [weak self] in
            guard let self, let location = await self.locationProvider.captureLocation(), !Task.isCancelled else { return }
            guard var session = self.currentSession, session.id == sessionID else { return }
            session.location = location
            session.updatedAt = Date()
            try? self.repository.save(session)
            self.currentSession = session
            self.reloadRecentSessions()
        }
    }

    private func applyAutomaticTitleIfNeeded(to original: MeetingSession) async -> MeetingSession {
        guard
            modelSettings.automaticMeetingTitle,
            original.title.hasPrefix("未命名会议 "),
            modelSettings.summaryIsConfigured,
            let endpoint = modelSettings.resolvedSummaryEndpoint
        else { return original }
        let finalSegments = transcriptSegments.filter(\.isFinal)
        guard !finalSegments.isEmpty else { return original }

        do {
            let response = try await summaryClient.summarize(
                title: original.title,
                segments: finalSegments,
                configuration: SummaryConfiguration(
                    endpoint: endpoint,
                    model: modelSettings.summaryModel,
                    apiKey: modelSettings.activeAPIKey,
                    prompt: "请只输出一个准确、具体的中文会议主题，不要解释、不要 Markdown、不要日期。长度 6 到 20 个汉字，必须基于逐字稿，不得编造。"
                )
            )
            guard let title = Self.cleanedAutomaticTitle(response) else { return original }
            var session = try repository.renameSession(original, to: title)
            session.titleWasAutomaticallyGenerated = true
            try repository.save(session)
            meetingTitle = session.title
            return session
        } catch {
            return original
        }
    }

    private static func cleanedAutomaticTitle(_ response: String) -> String? {
        var title = response.split(whereSeparator: \.isNewline).first.map(String.init) ?? response
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "“", with: "")
            .replacingOccurrences(of: "”", with: "")
        for prefix in ["会议主题：", "会议主题:", "主题：", "主题:"] where title.hasPrefix(prefix) {
            title.removeFirst(prefix.count)
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard title.count >= 2 else { return nil }
        return String(title.prefix(28))
    }

    private static func representativeTitleEvidence(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered = segments.sorted { $0.startTime < $1.startTime }
        let totalCharacters = ordered.reduce(0) { $0 + $1.text.count }
        guard totalCharacters > 12_000, ordered.count > 24 else { return ordered }
        let middleStart = max(0, ordered.count / 2 - 5)
        let middleEnd = min(ordered.count, middleStart + 10)
        var sampled = Array(ordered.prefix(10))
        sampled.append(contentsOf: ordered[middleStart..<middleEnd])
        sampled.append(contentsOf: ordered.suffix(10))
        var seen = Set<UUID>()
        return sampled.filter { seen.insert($0.id).inserted }.sorted { $0.startTime < $1.startTime }
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
