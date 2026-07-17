import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @ObservedObject private var models = DependencyContainer.shared.modelSettings

    var body: some View {
        TabView {
            recordingSettings
                .tabItem { Label("录音", systemImage: "waveform") }
            transcriptionSettings
                .tabItem { Label("语音识别", systemImage: "text.bubble") }
            summarySettings
                .tabItem { Label("会议总结", systemImage: "sparkles") }
            privacySettings
                .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 660, height: 520)
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
        }
        .formStyle(.grouped)
    }

    private var transcriptionSettings: some View {
        Form {
            Section("ASR / STT 模型") {
                Picker("服务", selection: $models.sttProvider) {
                    ForEach(STTProviderKind.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if models.sttProvider != .disabled {
                    LabeledContent("模型", value: models.resolvedSTTModel)
                    if let endpoint = models.resolvedSTTEndpoint {
                        LabeledContent("接口") {
                            Text(endpoint.absoluteString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if models.sttProvider == .customOpenAICompatible {
                        TextField("Base URL", text: $models.sttBaseURL, prompt: Text("https://example.com/v1"))
                        TextField("模型名称", text: $models.sttModel)
                    }
                    SecureField("API Key", text: $models.sttAPIKey)
                    Picker("识别语言", selection: $models.transcriptionLanguage) {
                        Text("自动识别").tag("auto")
                        Text("中文").tag("zh")
                        Text("英文").tag("en")
                    }
                }
            }

            Section {
                HStack(spacing: 8) {
                    Image(systemName: models.sttIsConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(models.sttIsConfigured ? .green : .orange)
                    Text(models.sttIsConfigured ? "模型已配置，录音时每约 10 秒生成一段文字。" : "请填写 API Key；未配置时只录音，不会上传音频。")
                }
                Text("MiMo 使用 mimo-v2.5-asr；智谱使用 glm-asr-2512。API Key 仅保存在 macOS 钥匙串。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var summarySettings: some View {
        Form {
            Section("总结大模型") {
                Picker("服务", selection: $models.summaryProvider) {
                    ForEach(SummaryProviderKind.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }

                if models.summaryProvider != .disabled {
                    if models.summaryProvider == .customOpenAICompatible {
                        TextField("Base URL", text: $models.summaryBaseURL, prompt: Text("https://example.com/v1"))
                    } else if let endpoint = models.resolvedSummaryEndpoint {
                        LabeledContent("接口") {
                            Text(endpoint.absoluteString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    TextField("模型名称", text: $models.summaryModel)
                    SecureField("API Key", text: $models.summaryAPIKey)
                    Toggle("转写完成后自动生成会议纪要", isOn: $models.automaticSummary)
                }
            }

            if models.summaryProvider != .disabled {
                Section("纪要要求") {
                    TextEditor(text: $models.summaryPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 130)
                }

                Section {
                    HStack(spacing: 8) {
                        Image(systemName: models.summaryIsConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(models.summaryIsConfigured ? .green : .orange)
                        Text(models.summaryIsConfigured ? "总结模型已配置。" : "请填写模型名称和 API Key。")
                    }
                    Text("MiMo、DeepSeek 和 GLM 在这里处理逐字稿文本，不会直接读取原始录音。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("数据流向") {
                LabeledContent("录音文件", value: "始终保存在本机")
                LabeledContent("语音片段") {
                    Text(models.sttProvider == .disabled ? "不发送" : "发送到你配置的 \(models.sttProvider.title)")
                }
                LabeledContent("逐字稿") {
                    Text(models.summaryProvider == .disabled ? "不发送" : "仅总结时发送到 \(models.summaryProvider.title)")
                }
            }
            Section {
                Label("所有 API Key 均保存在 macOS 钥匙串，不写入会议文件或日志。", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

