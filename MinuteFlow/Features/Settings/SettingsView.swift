import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @ObservedObject private var models = DependencyContainer.shared.modelSettings
    @ObservedObject private var aiDiagnostics = DependencyContainer.shared.aiDiagnostics
    @ObservedObject private var recordingDiagnostics = DependencyContainer.shared.recordingDiagnostics

    var body: some View {
        TabView {
            recordingSettings
                .tabItem { Label("录音", systemImage: "waveform") }
            aiServiceSettings
                .tabItem { Label("AI 服务", systemImage: "cpu") }
            diagnosticsSettings
                .tabItem { Label("检测", systemImage: "stethoscope") }
            privacySettings
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 700, height: 610)
        .task { await coordinator.refreshPermissionStates() }
    }

    private var recordingSettings: some View {
        Form {
            Section("默认录音") {
                Picker("声音来源", selection: $coordinator.sourceSelection) {
                    ForEach(AudioSourceSelection.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                LabeledContent("录音质量", value: "标准（AAC · 48 kHz）")
                LabeledContent("麦克风", value: coordinator.microphoneName)
            }
            Section("文件") {
                Text("会议目录自动使用日期、时间和会议名称展示；内部仍以稳定 ID 保存，防止改名后丢失关联。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aiServiceSettings: some View {
        Form {
            Section("一个连接") {
                TextField("连接名称", text: $models.connectionName, prompt: Text("例如 MiMo Token Plan"))
                TextField("Base URL", text: $models.baseURL, prompt: Text("https://token-plan-cn.xiaomimimo.com/v1"))
                SecureField("API Key / Token", text: $models.apiKey)
                LabeledContent("已识别协议", value: models.detectedASRTransport.title)
            }

            Section("语音识别") {
                Toggle("录音时自动转写", isOn: $models.asrEnabled)
                if models.asrEnabled {
                    TextField("ASR 模型", text: $models.asrModel, prompt: Text("mimo-v2.5-asr"))
                    Picker("识别语言", selection: $models.transcriptionLanguage) {
                        Text("自动识别").tag("auto")
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                    }
                    HStack {
                        Text("连续讲话最长切片")
                        Spacer()
                        Stepper(
                            "\(models.maximumChunkDuration, specifier: "%.0f") 秒",
                            value: $models.maximumChunkDuration,
                            in: 2...8,
                            step: 1
                        )
                        .labelsHidden()
                        Text("\(models.maximumChunkDuration, specifier: "%.0f") 秒")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text("检测到约 0.7 秒静音时会提前提交，不必等满设定时长。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("会议总结（可选）") {
                Toggle("启用会议总结", isOn: $models.summaryEnabled)
                if models.summaryEnabled {
                    TextField("总结模型", text: $models.summaryModel, prompt: Text("填写当前套餐支持的文本模型"))
                    Toggle("转写完成后自动生成", isOn: $models.automaticSummary)
                    DisclosureGroup("纪要提示词") {
                        TextEditor(text: $models.summaryPrompt)
                            .font(.system(size: 12))
                            .frame(minHeight: 100)
                    }
                    Text("ASR 模型负责听写，文本模型负责理解与总结；两者共用上面的 Base URL 和 Token，无需再创建连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("连接测试") {
                DiagnosticRow(title: "配置", state: aiDiagnostics.configurationState)
                DiagnosticRow(title: "语音识别", state: aiDiagnostics.asrState)
                DiagnosticRow(title: "会议总结", state: aiDiagnostics.summaryState)

                HStack {
                    Button {
                        Task { await aiDiagnostics.testAll(settings: models) }
                    } label: {
                        if aiDiagnostics.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("测试当前配置", systemImage: "bolt.horizontal.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aiDiagnostics.isRunning)
                    Spacer()
                    if let date = aiDiagnostics.lastTestDate {
                        Text("最近测试：\(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                DisclosureGroup("高级信息") {
                    LabeledContent("ASR 请求地址") {
                        Text(models.resolvedASREndpoint?.absoluteString ?? "配置无效")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("总结请求地址") {
                        Text(models.resolvedSummaryEndpoint?.absoluteString ?? "配置无效")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                Text("Base URL 和 Token 只填写一次。MiMo Token Plan 会自动使用 /chat/completions 和 input_audio 协议。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsSettings: some View {
        Form {
            Section("权限状态") {
                LabeledContent("当前运行的应用") {
                    Text(Bundle.main.bundleURL.lastPathComponent)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                PermissionRow(
                    title: "麦克风",
                    detail: "用于记录你的发言",
                    state: coordinator.microphonePermission,
                    request: { Task { await coordinator.requestPermission(.microphone) } },
                    openSettings: { coordinator.openPermissionSettings(.microphone) }
                )
                PermissionRow(
                    title: "屏幕与系统音频",
                    detail: "只捕获系统声音；打开系统开关后必须完全退出并重新打开本应用",
                    state: coordinator.systemAudioPermission,
                    request: { Task { await coordinator.requestPermission(.systemAudio) } },
                    openSettings: { coordinator.openPermissionSettings(.systemAudio) }
                )
                HStack {
                    Button("实际检测权限") {
                        Task { await coordinator.refreshPermissionStates() }
                    }
                    Button("完全退出 MinuteFlow") { NSApplication.shared.terminate(nil) }
                }
            }

            Section("五秒录音自检") {
                Text("测试期间请播放一段电脑声音，同时对着麦克风说话。测试文件只保存在临时目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DiagnosticRow(title: "系统声音", state: recordingDiagnostics.systemState)
                DiagnosticRow(title: "麦克风", state: recordingDiagnostics.microphoneState)

                HStack {
                    Button {
                        Task {
                            await recordingDiagnostics.run()
                            await coordinator.refreshPermissionStates()
                        }
                    } label: {
                        if recordingDiagnostics.isRunning {
                            Label("测试中 · \(recordingDiagnostics.countdown)", systemImage: "record.circle")
                        } else {
                            Label("开始五秒自检", systemImage: "waveform.badge.magnifyingglass")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recordingDiagnostics.isRunning || coordinator.status.isActive)

                    if recordingDiagnostics.lastSystemURL != nil {
                        Button("播放系统声") { recordingDiagnostics.playSystemSample() }
                    }
                    if recordingDiagnostics.lastMicrophoneURL != nil {
                        Button("播放麦克风") { recordingDiagnostics.playMicrophoneSample() }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("数据流向") {
                LabeledContent("原始录音", value: "始终保存在本机")
                LabeledContent("语音片段") {
                    Text(models.asrEnabled ? "发送到 \(models.serviceDisplayName)" : "不发送")
                }
                LabeledContent("逐字稿") {
                    Text(models.summaryEnabled ? "仅总结时发送到 \(models.serviceDisplayName)" : "不发送")
                }
            }
            Section {
                Label("Token 保存在 macOS 钥匙串，不会写入会议文件或运行日志。", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticRow: View {
    let title: String
    let state: DiagnosticState

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(state.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var icon: String {
        switch state {
        case .idle: "circle"
        case .testing: "clock.arrow.circlepath"
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch state {
        case .idle: .secondary
        case .testing: .blue
        case .success: .green
        case .failure: .red
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionAuthorizationState
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state == .authorized ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(state == .authorized ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(state == .authorized ? .green : .orange)
            if state != .authorized {
                Button(state == .notDetermined ? "请求" : "系统设置", action: state == .notDetermined ? request : openSettings)
            }
        }
    }
}
