import Combine
import Foundation

enum ASRTransport: String, Sendable {
    case miMoChatAudio
    case openAIAudioTranscription

    var title: String {
        switch self {
        case .miMoChatAudio: "MiMo Audio Chat"
        case .openAIAudioTranscription: "OpenAI Audio Transcription"
        }
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @Published var connectionName: String { didSet { save(connectionName, key: Keys.connectionName) } }
    @Published var baseURL: String { didSet { save(baseURL, key: Keys.baseURL) } }
    @Published var apiKey: String { didSet { KeychainStore.write(apiKey, key: Keys.apiKey) } }
    @Published var asrEnabled: Bool { didSet { save(asrEnabled, key: Keys.asrEnabled) } }
    @Published var asrModel: String { didSet { save(asrModel, key: Keys.asrModel) } }
    @Published var transcriptionLanguage: String { didSet { save(transcriptionLanguage, key: Keys.language) } }
    @Published var maximumChunkDuration: Double { didSet { save(maximumChunkDuration, key: Keys.maximumChunkDuration) } }

    @Published var summaryEnabled: Bool { didSet { save(summaryEnabled, key: Keys.summaryEnabled) } }
    @Published var summaryModel: String { didSet { save(summaryModel, key: Keys.summaryModel) } }
    @Published var automaticSummary: Bool { didSet { save(automaticSummary, key: Keys.automaticSummary) } }
    @Published var summaryPrompt: String { didSet { save(summaryPrompt, key: Keys.summaryPrompt) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let migratedBaseURL = defaults.string(forKey: LegacyKeys.sttBaseURL)
        connectionName = defaults.string(forKey: Keys.connectionName) ?? "MiMo Token Plan"
        baseURL = defaults.string(forKey: Keys.baseURL)
            ?? (migratedBaseURL?.isEmpty == false ? migratedBaseURL! : "https://token-plan-cn.xiaomimimo.com/v1")

        let currentKey = KeychainStore.read(key: Keys.apiKey)
        let legacyKey = KeychainStore.read(key: LegacyKeys.sttAPIKey)
        apiKey = currentKey.isEmpty ? legacyKey : currentKey

        asrEnabled = defaults.object(forKey: Keys.asrEnabled) as? Bool ?? true
        asrModel = defaults.string(forKey: Keys.asrModel)
            ?? defaults.string(forKey: LegacyKeys.sttModel)
            ?? "mimo-v2.5-asr"
        transcriptionLanguage = defaults.string(forKey: Keys.language)
            ?? defaults.string(forKey: LegacyKeys.language)
            ?? "auto"
        maximumChunkDuration = defaults.object(forKey: Keys.maximumChunkDuration) as? Double ?? 3

        summaryEnabled = defaults.object(forKey: Keys.summaryEnabled) as? Bool ?? false
        summaryModel = defaults.string(forKey: Keys.summaryModel)
            ?? defaults.string(forKey: LegacyKeys.summaryModel)
            ?? ""
        automaticSummary = defaults.bool(forKey: Keys.automaticSummary)
        summaryPrompt = defaults.string(forKey: Keys.summaryPrompt)
            ?? defaults.string(forKey: LegacyKeys.summaryPrompt)
            ?? Self.defaultSummaryPrompt

        if currentKey.isEmpty, !legacyKey.isEmpty {
            KeychainStore.write(legacyKey, key: Keys.apiKey)
        }
    }

    var connectionIsConfigured: Bool {
        resolvedBaseURL != nil && !apiKey.isEmpty
    }

    var asrIsConfigured: Bool {
        asrEnabled && connectionIsConfigured && !asrModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summaryIsConfigured: Bool {
        summaryEnabled && connectionIsConfigured && !summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var resolvedBaseURL: URL? {
        Self.normalizedBaseURL(baseURL)
    }

    var detectedASRTransport: ASRTransport {
        guard let host = resolvedBaseURL?.host?.lowercased() else {
            return .openAIAudioTranscription
        }
        return host.contains("xiaomimimo.com") ? .miMoChatAudio : .openAIAudioTranscription
    }

    var resolvedASREndpoint: URL? {
        switch detectedASRTransport {
        case .miMoChatAudio:
            return Self.endpoint(baseURL: baseURL, suffix: "chat/completions")
        case .openAIAudioTranscription:
            return Self.endpoint(baseURL: baseURL, suffix: "audio/transcriptions")
        }
    }

    var resolvedSummaryEndpoint: URL? {
        Self.endpoint(baseURL: baseURL, suffix: "chat/completions")
    }

    var serviceDisplayName: String {
        let trimmed = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (resolvedBaseURL?.host ?? "AI 服务") : trimmed
    }

    static let defaultSummaryPrompt = """
    请根据会议逐字稿生成可靠的 Markdown 会议纪要，包含：会议概述、核心议题、主要讨论内容、已确认结论、待办事项表格、风险与待确认事项、关键原文。不得编造负责人或截止时间；原文未明确时写“待确认”。
    """

    private let defaults: UserDefaults

    private func save(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
    }

    private static func normalizedBaseURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func endpoint(baseURL: String, suffix: String) -> URL? {
        guard let normalized = normalizedBaseURL(baseURL) else { return nil }
        let value = normalized.absoluteString
        if value.hasSuffix(suffix) { return normalized }
        return URL(string: "\(value)/\(suffix)")
    }

    private enum Keys {
        static let connectionName = "models.connection.name"
        static let baseURL = "models.connection.baseURL"
        static let apiKey = "models.connection.apiKey"
        static let asrEnabled = "models.asr.enabled"
        static let asrModel = "models.asr.model"
        static let language = "models.asr.language"
        static let maximumChunkDuration = "models.asr.maximumChunkDuration"
        static let summaryEnabled = "models.summary.enabled"
        static let summaryModel = "models.summary.unifiedModel"
        static let automaticSummary = "models.summary.automatic"
        static let summaryPrompt = "models.summary.prompt.unified"
    }

    private enum LegacyKeys {
        static let sttBaseURL = "models.stt.baseURL"
        static let sttModel = "models.stt.model"
        static let sttAPIKey = "models.stt.apiKey"
        static let language = "models.stt.language"
        static let summaryModel = "models.summary.model"
        static let summaryPrompt = "models.summary.prompt"
    }
}

