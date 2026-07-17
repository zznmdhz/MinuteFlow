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

enum CredentialPersistenceState: Equatable, Sendable {
    case missing
    case savedToKeychain
    case savedToProtectedFile
    case failure(String)

    var message: String {
        switch self {
        case .missing: "尚未填写 Token"
        case .savedToKeychain: "已安全保存到 macOS 钥匙串"
        case .savedToProtectedFile: "系统钥匙串不可用；已保存到仅当前用户可读的本机保护文件"
        case .failure(let message): message
        }
    }
}

@MainActor
final class ModelSettingsStore: ObservableObject {
    @Published var connectionName: String { didSet { save(connectionName, key: Keys.connectionName) } }
    @Published var baseURL: String { didSet { save(baseURL, key: Keys.baseURL) } }
    @Published var apiKey: String { didSet { persistCredential() } }
    @Published private(set) var credentialPersistenceState: CredentialPersistenceState
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
        Self.migrateSandboxedDefaultsIfNeeded(into: defaults)

        let migratedBaseURL = defaults.string(forKey: LegacyKeys.sttBaseURL)
        connectionName = defaults.string(forKey: Keys.connectionName) ?? "MiMo Token Plan"
        baseURL = defaults.string(forKey: Keys.baseURL)
            ?? (migratedBaseURL?.isEmpty == false ? migratedBaseURL! : "https://token-plan-cn.xiaomimimo.com/v1")

        var currentCredential = StoredCredentialResult(value: "", backend: nil)
        var legacyCredential = StoredCredentialResult(value: "", backend: nil)
        var credentialReadError: Error?
        do {
            currentCredential = try CredentialStore.read(key: Keys.apiKey)
            legacyCredential = try CredentialStore.read(key: LegacyKeys.sttAPIKey)
        } catch {
            credentialReadError = error
        }

        let resolvedCredential = currentCredential.value.isEmpty ? legacyCredential : currentCredential
        let resolvedKey = resolvedCredential.value
        apiKey = resolvedKey
        credentialPersistenceState = credentialReadError.map { .failure($0.localizedDescription) }
            ?? Self.persistenceState(for: resolvedCredential)

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

        if credentialReadError == nil, currentCredential.value.isEmpty, !legacyCredential.value.isEmpty {
            do {
                let backend = try CredentialStore.write(legacyCredential.value, key: Keys.apiKey)
                credentialPersistenceState = Self.persistenceState(for: backend)
            } catch {
                credentialPersistenceState = .failure(error.localizedDescription)
            }
        }
    }

    func retrySavingCredential() {
        persistCredential()
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

    private func persistCredential() {
        do {
            let backend = try CredentialStore.write(apiKey, key: Keys.apiKey)
            let storedValue = try CredentialStore.read(key: Keys.apiKey).value
            guard storedValue == apiKey else {
                credentialPersistenceState = .failure("Token 回读验证失败，请点击“保存”重试。")
                return
            }
            credentialPersistenceState = Self.persistenceState(for: backend)
        } catch {
            credentialPersistenceState = .failure(error.localizedDescription)
        }
    }

    private static func persistenceState(for result: StoredCredentialResult) -> CredentialPersistenceState {
        guard !result.value.isEmpty else { return .missing }
        return persistenceState(for: result.backend)
    }

    private static func persistenceState(for backend: CredentialStorageBackend?) -> CredentialPersistenceState {
        switch backend {
        case .keychain: .savedToKeychain
        case .protectedFile: .savedToProtectedFile
        case nil: .missing
        }
    }

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

    private static func migrateSandboxedDefaultsIfNeeded(into defaults: UserDefaults) {
        let legacyURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/com.minuteflow.app/Data/Library/Preferences/com.minuteflow.app.plist")
        guard
            let dictionary = NSDictionary(contentsOf: legacyURL) as? [String: Any]
        else { return }

        for (key, value) in dictionary where defaults.object(forKey: key) == nil {
            if key.hasPrefix("models.") || key == "defaultAudioSource" {
                defaults.set(value, forKey: key)
            }
        }
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
