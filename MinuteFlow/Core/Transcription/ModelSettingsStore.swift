import Combine
import Foundation

enum STTProviderKind: String, CaseIterable, Identifiable, Sendable {
    case xiaomiMiMo
    case zhipuGLM
    case customOpenAICompatible
    case disabled

    var id: Self { self }
    var title: String {
        switch self {
        case .xiaomiMiMo: "小米 MiMo ASR"
        case .zhipuGLM: "智谱 GLM-ASR"
        case .customOpenAICompatible: "自定义 ASR API"
        case .disabled: "关闭转写"
        }
    }
}

enum SummaryProviderKind: String, CaseIterable, Identifiable, Sendable {
    case xiaomiMiMo
    case deepSeek
    case zhipuGLM
    case customOpenAICompatible
    case disabled

    var id: Self { self }
    var title: String {
        switch self {
        case .xiaomiMiMo: "小米 MiMo"
        case .deepSeek: "DeepSeek"
        case .zhipuGLM: "智谱 GLM"
        case .customOpenAICompatible: "自定义 OpenAI Compatible"
        case .disabled: "关闭会议总结"
        }
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @Published var sttProvider: STTProviderKind { didSet { save(sttProvider.rawValue, key: Keys.sttProvider) } }
    @Published var sttBaseURL: String { didSet { save(sttBaseURL, key: Keys.sttBaseURL) } }
    @Published var sttModel: String { didSet { save(sttModel, key: Keys.sttModel) } }
    @Published var sttAPIKey: String { didSet { KeychainStore.write(sttAPIKey, key: Keys.sttAPIKey) } }
    @Published var transcriptionLanguage: String { didSet { save(transcriptionLanguage, key: Keys.language) } }

    @Published var summaryProvider: SummaryProviderKind {
        didSet {
            save(summaryProvider.rawValue, key: Keys.summaryProvider)
            if oldValue != summaryProvider {
                summaryModel = Self.defaultSummaryModel(for: summaryProvider)
            }
        }
    }
    @Published var summaryBaseURL: String { didSet { save(summaryBaseURL, key: Keys.summaryBaseURL) } }
    @Published var summaryModel: String { didSet { save(summaryModel, key: Keys.summaryModel) } }
    @Published var summaryAPIKey: String { didSet { KeychainStore.write(summaryAPIKey, key: Keys.summaryAPIKey) } }
    @Published var automaticSummary: Bool { didSet { save(automaticSummary, key: Keys.automaticSummary) } }
    @Published var summaryPrompt: String { didSet { save(summaryPrompt, key: Keys.summaryPrompt) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sttProvider = STTProviderKind(rawValue: defaults.string(forKey: Keys.sttProvider) ?? "") ?? .xiaomiMiMo
        sttBaseURL = defaults.string(forKey: Keys.sttBaseURL) ?? ""
        sttModel = defaults.string(forKey: Keys.sttModel) ?? "mimo-v2.5-asr"
        sttAPIKey = KeychainStore.read(key: Keys.sttAPIKey)
        transcriptionLanguage = defaults.string(forKey: Keys.language) ?? "zh-CN"

        summaryProvider = SummaryProviderKind(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "") ?? .disabled
        summaryBaseURL = defaults.string(forKey: Keys.summaryBaseURL) ?? ""
        summaryModel = defaults.string(forKey: Keys.summaryModel) ?? "deepseek-chat"
        summaryAPIKey = KeychainStore.read(key: Keys.summaryAPIKey)
        automaticSummary = defaults.bool(forKey: Keys.automaticSummary)
        summaryPrompt = defaults.string(forKey: Keys.summaryPrompt) ?? Self.defaultSummaryPrompt
    }

    var sttIsConfigured: Bool {
        switch sttProvider {
        case .xiaomiMiMo, .zhipuGLM:
            !sttAPIKey.isEmpty
        case .customOpenAICompatible:
            !sttBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !sttModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !sttAPIKey.isEmpty
        case .disabled: false
        }
    }

    var summaryIsConfigured: Bool {
        switch summaryProvider {
        case .xiaomiMiMo, .deepSeek, .zhipuGLM:
            !summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !summaryAPIKey.isEmpty
        case .customOpenAICompatible:
            !summaryBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !summaryAPIKey.isEmpty
        case .disabled:
            false
        }
    }

    var resolvedSTTEndpoint: URL? {
        switch sttProvider {
        case .xiaomiMiMo:
            URL(string: "https://api.xiaomimimo.com/v1/chat/completions")
        case .zhipuGLM:
            URL(string: "https://open.bigmodel.cn/api/paas/v4/audio/transcriptions")
        case .customOpenAICompatible:
            Self.endpoint(baseURL: sttBaseURL, suffix: "audio/transcriptions")
        case .disabled:
            nil
        }
    }

    var resolvedSTTModel: String {
        switch sttProvider {
        case .xiaomiMiMo: "mimo-v2.5-asr"
        case .zhipuGLM: "glm-asr-2512"
        case .customOpenAICompatible: sttModel
        case .disabled: ""
        }
    }

    var resolvedSummaryEndpoint: URL? {
        switch summaryProvider {
        case .xiaomiMiMo:
            URL(string: "https://api.xiaomimimo.com/v1/chat/completions")
        case .deepSeek:
            URL(string: "https://api.deepseek.com/chat/completions")
        case .zhipuGLM:
            URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")
        case .customOpenAICompatible:
            Self.endpoint(baseURL: summaryBaseURL, suffix: "chat/completions")
        case .disabled:
            nil
        }
    }

    static func defaultSummaryModel(for provider: SummaryProviderKind) -> String {
        switch provider {
        case .xiaomiMiMo: "mimo-v2.5"
        case .deepSeek: "deepseek-chat"
        case .zhipuGLM: "glm-4.5-flash"
        case .customOpenAICompatible, .disabled: ""
        }
    }

    private static func endpoint(baseURL: String, suffix: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix(suffix) { return URL(string: trimmed) }
        return URL(string: "\(trimmed)/\(suffix)")
    }

    static let defaultSummaryPrompt = """
    请根据会议逐字稿生成可靠的 Markdown 会议纪要，包含：会议概述、核心议题、主要讨论内容、已确认结论、待办事项表格、风险与待确认事项、关键原文。不得编造负责人或截止时间；原文未明确时写“待确认”。
    """

    private let defaults: UserDefaults

    private func save(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
    }

    private enum Keys {
        static let sttProvider = "models.stt.provider"
        static let sttBaseURL = "models.stt.baseURL"
        static let sttModel = "models.stt.model"
        static let sttAPIKey = "models.stt.apiKey"
        static let language = "models.stt.language"
        static let summaryProvider = "models.summary.provider"
        static let summaryBaseURL = "models.summary.baseURL"
        static let summaryModel = "models.summary.model"
        static let summaryAPIKey = "models.summary.apiKey"
        static let automaticSummary = "models.summary.automatic"
        static let summaryPrompt = "models.summary.prompt"
    }
}
