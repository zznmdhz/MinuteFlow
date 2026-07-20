import Foundation

struct ASRConfiguration: Sendable {
    let transport: ASRTransport
    let endpoint: URL
    let model: String
    let apiKey: String
    let language: String
}

enum RemoteModelError: LocalizedError, Sendable {
    case invalidConfiguration
    case invalidResponse
    case server(status: Int, message: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "模型配置不完整。请检查服务地址、模型名称和 API Key。"
        case .invalidResponse: return "模型服务返回了无法解析的响应。"
        case .server(let status, let message):
            let action: String
            switch status {
            case 400: action = "请检查模型名称、语言或请求协议。"
            case 401, 403: action = "请检查 Token 是否有效以及是否有该模型权限。"
            case 404: action = "请检查 Base URL 和模型服务地址。"
            case 408: action = "请求超时，请检查网络后重试。"
            case 429: action = "请求过于频繁或额度不足，稍后会自动重试。"
            case 500...599: action = "服务暂时异常，稍后会自动重试。"
            default: action = "请检查服务配置后重试。"
            }
            let safeMessage = String(message.prefix(240))
            return "模型服务请求失败（\(status)）。\(action)\(safeMessage.isEmpty ? "" : " 服务信息：\(safeMessage)")"
        case .emptyResult: return "模型服务未返回识别文字。"
        }
    }
}

protocol ASRClient: Sendable {
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String
}

struct RemoteASRClient: ASRClient, Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }
    func transcribe(wavURL: URL, configuration: ASRConfiguration) async throws -> String {
        switch configuration.transport {
        case .miMoChatAudio:
            return try await transcribeWithMiMo(wavURL: wavURL, configuration: configuration)
        case .openAIAudioTranscription:
            return try await transcribeMultipart(wavURL: wavURL, configuration: configuration)
        }
    }

    private func transcribeWithMiMo(
        wavURL: URL,
        configuration: ASRConfiguration
    ) async throws -> String {
        let audioData = try Data(contentsOf: wavURL)
        let language = Self.normalizedLanguage(configuration.language)
        let payload: [String: Any] = [
            "model": configuration.model,
            "messages": [[
                "role": "user",
                "content": [[
                    "type": "input_audio",
                    "input_audio": [
                        "data": "data:audio/wav;base64,\(audioData.base64EncodedString())"
                    ]
                ]]
            ]],
            "asr_options": ["language": language],
            "stream": false
        ]

        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 45
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        APIRequestAuthentication.apply(apiKey: configuration.apiKey, endpoint: configuration.endpoint, to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await perform(request)
    }

    private func transcribeMultipart(
        wavURL: URL,
        configuration: ASRConfiguration
    ) async throws -> String {
        let boundary = "MinuteFlow-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart(name: "model", value: configuration.model, boundary: boundary)
        body.appendMultipart(name: "stream", value: "false", boundary: boundary)
        if configuration.transport == .openAIAudioTranscription,
           configuration.language != "auto" {
            body.appendMultipart(
                name: "language",
                value: Self.normalizedLanguage(configuration.language),
                boundary: boundary
            )
        }
        try body.appendFile(
            name: "file",
            fileName: wavURL.lastPathComponent,
            mimeType: "audio/wav",
            fileURL: wavURL,
            boundary: boundary
        )
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: configuration.endpoint)
        request.timeoutInterval = 45
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        APIRequestAuthentication.apply(apiKey: configuration.apiKey, endpoint: configuration.endpoint, to: &request)
        request.httpBody = body
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = Self.errorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "未知错误"
            throw RemoteModelError.server(status: httpResponse.statusCode, message: message)
        }

        let decoded = try JSONDecoder().decode(ModelTextResponse.self, from: data)
        let text = (decoded.text ?? decoded.choices?.first?.message.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RemoteModelError.emptyResult }
        return text
    }

    private static func errorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(ModelErrorEnvelope.self, from: data))?.error.message
    }

    private static func normalizedLanguage(_ language: String) -> String {
        switch language.lowercased() {
        case "zh-cn", "zh": "zh"
        case "en-us", "en": "en"
        default: "auto"
        }
    }
}

private struct ModelTextResponse: Decodable {
    let text: String?
    let choices: [Choice]?

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: String
    }
}

private struct ModelErrorEnvelope: Decodable {
    let error: ModelError
    struct ModelError: Decodable { let message: String }
}

private extension Data {
    mutating func appendMultipart(name: String, value: String, boundary: String) {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        append(Data("\(value)\r\n".utf8))
    }

    mutating func appendFile(
        name: String,
        fileName: String,
        mimeType: String,
        fileURL: URL,
        boundary: String
    ) throws {
        append(Data("--\(boundary)\r\n".utf8))
        append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n".utf8))
        append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        append(try Data(contentsOf: fileURL))
        append(Data("\r\n".utf8))
    }
}
