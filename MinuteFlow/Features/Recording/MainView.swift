import AppKit
import SwiftUI

struct MainView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        HSplitView {
            SidebarView()
                .environmentObject(coordinator)
                .frame(minWidth: 220, idealWidth: 248, maxWidth: 290)

            RecorderView()
                .environmentObject(coordinator)
                .frame(minWidth: 600)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openSettings) private var openSettings
    @State private var sessionPendingDeletion: MeetingSession?
    @State private var sessionPendingRename: MeetingSession?
    @State private var renameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("MinuteFlow")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本地会议录音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 22)

            Button { coordinator.prepareNewRecording() } label: {
                Label("新建录音", systemImage: "record.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)

            Text("最近保存")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 8)

            if coordinator.recentSessions.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("录音完成后会显示在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(coordinator.recentSessions) { session in
                            RecentSessionRow(
                                session: session,
                                selected: coordinator.currentSession?.id == session.id,
                                onSelect: { coordinator.selectSession(session) },
                                onRename: {
                                    renameDraft = session.title
                                    sessionPendingRename = session
                                },
                                onReveal: { coordinator.openSessionFolder(session) },
                                onDelete: { sessionPendingDeletion = session }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 12)
            Divider()
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .confirmationDialog(
            "删除“\(sessionPendingDeletion?.title ?? "这条会议")”？",
            isPresented: Binding(
                get: { sessionPendingDeletion != nil },
                set: { if !$0 { sessionPendingDeletion = nil } }
            )
        ) {
            Button("删除录音、逐字稿和纪要", role: .destructive) {
                if let sessionPendingDeletion {
                    coordinator.deleteSession(sessionPendingDeletion)
                }
                sessionPendingDeletion = nil
            }
            Button("取消", role: .cancel) { sessionPendingDeletion = nil }
        } message: {
            Text("此操作会删除该会议目录中的全部本地文件，无法撤销。")
        }
        .alert(
            "重命名会议",
            isPresented: Binding(
                get: { sessionPendingRename != nil },
                set: {
                    if !$0 {
                        sessionPendingRename = nil
                        renameDraft = ""
                    }
                }
            )
        ) {
            TextField("会议名称", text: $renameDraft)
            Button("保存") {
                if let sessionPendingRename {
                    coordinator.renameSession(sessionPendingRename, to: renameDraft)
                }
                sessionPendingRename = nil
                renameDraft = ""
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {
                sessionPendingRename = nil
                renameDraft = ""
            }
        } message: {
            Text("重命名只改变会议标题，原始录音和文档的关联不会改变。")
        }
    }
}

private struct RecentSessionRow: View {
    let session: MeetingSession
    let selected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 9) {
                    Image(systemName: session.transcriptFileURL == nil ? "waveform.circle.fill" : "text.bubble.fill")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("\(session.startTime.formatted(date: .abbreviated, time: .shortened)) · \(DurationFormatter.string(from: session.duration))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("删除这条会议")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("重命名…", systemImage: "pencil", action: onRename)
            Button("在 Finder 中显示", systemImage: "folder", action: onReveal)
            Divider()
            Button("删除会议", role: .destructive, action: onDelete)
        }
    }
}

private struct RecorderView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @ObservedObject private var models = DependencyContainer.shared.modelSettings

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                if let permissionIssue = coordinator.permissionIssue {
                    PermissionBanner(issue: permissionIssue)
                }

                if let message = coordinator.userMessage {
                    NoticeBanner(message: message)
                }

                recorderCard
                sourcePanel
                if let session = coordinator.currentSession,
                   session.recordingStatus == .completed {
                    RecordingFilesPanel(session: session)
                        .environmentObject(coordinator)
                }
                TranscriptPanel()
                    .environmentObject(coordinator)

                if coordinator.currentSession != nil,
                   coordinator.transcriptSegments.contains(where: \.isFinal) {
                    FormattedDocumentPanel()
                        .environmentObject(coordinator)
                }

                if coordinator.currentSession != nil,
                   !coordinator.transcriptSegments.isEmpty || coordinator.summaryMarkdown != nil {
                    SummaryPanel()
                        .environmentObject(coordinator)
                }

                HStack(spacing: 6) {
                    Image(systemName: models.asrEnabled ? "network" : "lock.shield.fill")
                        .foregroundStyle(models.asrEnabled ? Color.accentColor : .green)
                    Text(!models.asrEnabled
                         ? "录音和文字仅保存在此 Mac"
                         : "录音保存在本机；动态语音片段发送给 \(models.serviceDisplayName)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("开始一次清晰、可靠的录音")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("完整回放用于直接播放，系统声音与麦克风原始分轨同时保留。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: coordinator.status)
        }
    }

    private var recorderCard: some View {
        VStack(spacing: 20) {
            TextField("会议名称（可选）", text: $coordinator.meetingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
                .disabled(coordinator.status.isActive)
                .padding(.horizontal, 60)
                .onSubmit { coordinator.renameCurrentMeeting() }

            ZStack {
                RecordingStatusHalo(status: coordinator.status)

                VStack(spacing: 8) {
                    Image(systemName: coordinator.isPaused ? "pause.fill" : "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(coordinator.status.isActive ? Color.red : Color.accentColor)
                    Text(DurationFormatter.string(from: coordinator.elapsedTime))
                        .font(.system(size: 27, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                    Text(coordinator.status.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            controls
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    @ViewBuilder
    private var controls: some View {
        if coordinator.isRecording {
            HStack(spacing: 12) {
                Button { coordinator.pauseRecording() } label: {
                    Label("暂停", systemImage: "pause.fill")
                        .frame(minWidth: 86)
                }
                .controlSize(.large)

                Button(role: .destructive) {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
            }
        } else if coordinator.isPaused {
            HStack(spacing: 12) {
                Button { coordinator.resumeRecording() } label: {
                    Label("继续", systemImage: "play.fill")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
            }
        } else if coordinator.status == .saving || coordinator.status == .preparing {
            ProgressView()
                .controlSize(.large)
        } else {
            Button {
                Task { await coordinator.startRecording() }
            } label: {
                Label("开始录音", systemImage: "record.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 136)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            if coordinator.status == .completed, coordinator.currentSession != nil {
                Button("在 Finder 中显示") { coordinator.openCurrentSessionFolder() }
                    .buttonStyle(.link)
            }
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("声音来源")
                    .font(.headline)
                Spacer()
                Picker("声音来源", selection: $coordinator.sourceSelection) {
                    ForEach(AudioSourceSelection.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(coordinator.status.isActive)
                .frame(width: 190)
            }

            HStack(spacing: 12) {
                SourceCard(
                    icon: "macbook.and.iphone",
                    title: "系统声音",
                    detail: "会议应用与浏览器",
                    enabled: coordinator.sourceSelection.systemAudioEnabled,
                    level: coordinator.systemLevel
                )
                SourceCard(
                    icon: "mic.fill",
                    title: "麦克风",
                    detail: coordinator.microphoneName,
                    enabled: coordinator.sourceSelection.microphoneEnabled,
                    level: coordinator.microphoneLevel
                )
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RecordingFilesPanel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会议录音", systemImage: "waveform.circle")
                    .font(.headline)
                Spacer()
                Button("在 Finder 中显示") { coordinator.openCurrentSessionFolder() }
                    .buttonStyle(.link)
            }

            if let url = session.mixedAudioURL,
               FileManager.default.fileExists(atPath: url.path) {
                AudioFileRow(title: "完整回放", badge: "推荐", badgeColor: .blue, url: url) {
                    coordinator.openAudioFile(url)
                }
            } else if session.mixState == .processing || session.mixState == .queued {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在生成完整回放，原始分轨已经安全保存")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if session.mixState == .failed {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(session.mixMessage ?? "完整回放暂未生成，可继续播放原始分轨。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("重新生成") {
                        Task { await coordinator.retryCompletePlayback(sessionID: session.id) }
                    }
                    .controlSize(.small)
                }
            }

            DisclosureGroup("原始分轨") {
                VStack(spacing: 10) {
                    if let url = session.systemAudioURL {
                        AudioFileRow(title: "系统声音", badge: "原始文件", badgeColor: .green, url: url) {
                            coordinator.openAudioFile(url)
                        }
                    }
                    if let url = session.microphoneAudioURL {
                        AudioFileRow(title: "麦克风", badge: "原始文件", badgeColor: .green, url: url) {
                            coordinator.openAudioFile(url)
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AudioFileRow: View {
    let title: String
    let badge: String
    let badgeColor: Color
    let url: URL
    let play: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform")
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badgeColor)
                }
                Text("\(url.lastPathComponent) · \(fileSizeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(action: play) { Label("播放", systemImage: "play.fill") }
                .controlSize(.small)
        }
    }

    private var fileSizeText: String {
        guard
            let value = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return "文件不可用" }
        return ByteCountFormatter.string(fromByteCount: value.int64Value, countStyle: .file)
    }
}

private struct TranscriptPanel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openSettings) private var openSettings
    @State private var viewMode: TranscriptViewMode = .edited

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时逐字稿", systemImage: "text.bubble.fill")
                    .font(.headline)
                Spacer()
                if coordinator.currentSession != nil,
                   coordinator.transcriptSegments.contains(where: \.isFinal) {
                    Button("逐字稿文件", systemImage: "folder") {
                        coordinator.revealTranscriptInFinder()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                HStack(spacing: 6) {
                    if coordinator.status.isActive {
                        ProgressView().controlSize(.small)
                    }
                    Text(coordinator.transcriptionActivity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !coordinator.transcriptSegments.isEmpty {
                HStack(spacing: 10) {
                    Picker("逐字稿显示", selection: $viewMode) {
                        ForEach(TranscriptViewMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Spacer()

                    Button("基础文本校正", systemImage: "text.badge.checkmark") {
                        coordinator.normalizeTranscript()
                        viewMode = .normalized
                    }
                    .controlSize(.small)
                    .help("仅在本地处理空格、标点和断句，不调用 AI，也不会覆盖原始识别文本")
                }

                Text("“基础文本校正”不调用 AI，只处理空格、标点和断句；需要按主题自动排版时，请使用下方的“AI 排版文稿”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if coordinator.transcriptSegments.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "quote.bubble")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(emptyTranscriptMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !coordinator.modelSettings.asrIsConfigured {
                        Button("配置 AI 语音识别") { openSettings() }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                LazyVStack(alignment: .leading, spacing: 13) {
                    ForEach(coordinator.transcriptSegments) { segment in
                        HStack(alignment: .top, spacing: 12) {
                            Text(DurationFormatter.string(from: segment.startTime))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 62, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(segment.source.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(segment.source == .microphone ? .orange : Color.accentColor)
                                if !segment.isFinal {
                                    Text("识别中")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                transcriptContent(for: segment)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }

    private var emptyTranscriptMessage: String {
        guard coordinator.status.isActive else { return "当前会议还没有逐字稿" }
        return "连续讲话约 3 秒先显示临时文字；停顿后自动定稿并按内容分段"
    }

    @ViewBuilder
    private func transcriptContent(for segment: TranscriptSegment) -> some View {
        if !segment.isFinal {
            Text(segment.text)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            switch viewMode {
            case .original:
                Text(segment.originalText ?? segment.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .edited:
                VStack(alignment: .trailing, spacing: 4) {
                    TextEditor(text: Binding(
                        get: { segment.text },
                        set: { coordinator.updateTranscriptSegment(id: segment.id, text: $0) }
                    ))
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 7))

                    if let original = segment.originalText, original != segment.text {
                        Button("恢复原文") {
                            coordinator.restoreOriginalTranscriptSegment(id: segment.id)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            case .normalized:
                Text(segment.normalizedText ?? segment.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private enum TranscriptViewMode: String, CaseIterable, Identifiable {
    case original
    case edited
    case normalized

    var id: Self { self }

    var title: String {
        switch self {
        case .original: "原始识别"
        case .edited: "编辑文本"
        case .normalized: "校正后"
        }
    }
}

private struct FormattedDocumentPanel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AI 排版文稿", systemImage: "doc.richtext.fill")
                    .font(.headline)
                Spacer()

                if coordinator.formattedDocumentMarkdown != nil {
                    Button("在 Finder 中查看", systemImage: "folder") {
                        coordinator.revealFormattedDocumentInFinder()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }

                if coordinator.isGeneratingDocument {
                    ProgressView().controlSize(.small)
                    Text("正在整理…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(
                        coordinator.formattedDocumentMarkdown == nil ? "生成排版文稿" : "重新生成",
                        systemImage: "wand.and.stars"
                    ) {
                        Task { await coordinator.generateFormattedDocument() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(coordinator.status.isActive)
                }
            }

            if let document = coordinator.formattedDocumentMarkdown {
                Text(document)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .lineLimit(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("完整内容已保存为 Markdown 文档，可在 Finder 中使用任意文档编辑器打开。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if coordinator.modelSettings.summaryIsConfigured {
                Text("使用当前配置的同一个总结模型，把逐字稿去除口头重复、合并自然段并按主题生成 Markdown 文档；它保留原意，不等同于会议摘要。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("AI 排版文稿使用同一个总结模型，不需要再配置一套模型。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("打开 AI 服务设置") { openSettings() }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SummaryPanel: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("会议纪要", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if coordinator.summaryMarkdown != nil {
                    Button("在 Finder 中查看", systemImage: "folder") {
                        coordinator.revealSummaryInFinder()
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
                if coordinator.isGeneratingSummary {
                    ProgressView().controlSize(.small)
                    Text("正在生成…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(coordinator.summaryMarkdown == nil ? "生成纪要" : "重新生成") {
                        Task { await coordinator.generateSummary() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(
                        coordinator.status.isActive
                            || !coordinator.transcriptSegments.contains(where: \.isFinal)
                    )
                }
            }

            if let summary = coordinator.summaryMarkdown {
                Text(summary)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !coordinator.modelSettings.summaryIsConfigured {
                VStack(spacing: 8) {
                    Text("在同一个 AI 服务连接中配置总结模型后，可根据逐字稿生成结构化会议纪要。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("打开 AI 服务设置") { openSettings() }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct RecordingStatusHalo: View {
    let status: RecordingStatus
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.06), lineWidth: 14)
                .frame(width: 168, height: 168)

            if status == .recording {
                Circle()
                    .stroke(Color.red.opacity(pulsing ? 0.08 : 0.34), lineWidth: 5)
                    .frame(width: 168, height: 168)
                    .scaleEffect(pulsing ? 1.12 : 1)
                Circle()
                    .stroke(Color.red, lineWidth: 5)
                    .frame(width: 168, height: 168)
            } else if status == .paused {
                Circle()
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 5, dash: [8, 6]))
                    .frame(width: 168, height: 168)
            } else if status == .preparing || status == .saving {
                ProgressView()
                    .controlSize(.large)
                    .offset(y: 54)
            } else if status == .completed {
                Circle()
                    .stroke(Color.green.opacity(0.75), lineWidth: 5)
                    .frame(width: 168, height: 168)
            }
        }
        .onAppear { updateAnimation() }
        .onChange(of: status) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        pulsing = false
        guard status == .recording else { return }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulsing = true
        }
    }
}

private struct SourceCard: View {
    let icon: String
    let title: String
    let detail: String
    let enabled: Bool
    let level: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(enabled ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(enabled ? "已启用" : "未启用")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(enabled ? .green : .secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AudioLevelView(level: enabled ? level : 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .opacity(enabled ? 1 : 0.58)
    }
}

private struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .paused: .orange
        case .failed: .red
        case .completed: .green
        default: .secondary
        }
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let issue: PermissionIssue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.subheadline.weight(.semibold))
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开系统设置") { coordinator.openPermissionSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.22)) }
    }
}

private struct NoticeBanner: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { coordinator.dismissMessage() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
