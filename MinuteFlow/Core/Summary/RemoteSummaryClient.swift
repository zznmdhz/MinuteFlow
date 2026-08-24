import Foundation

struct SummaryConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
    let prompt: String
}

protocol SummaryClient: Sendable {
    func summarize(
        title: String,
        segments: [TranscriptSegment],
        configuration: SummaryConfiguration
    ) async throws -> String
}

struct RemoteSummaryClient: SummaryClient, Sendable {
    private let session: URLSession
    private let maximumChunkCharacters: Int

    init(session: URLSession = .shared, maximumChunkCharacters: Int = 24_000) {
        self.session = session
        self.maximumChunkCharacters = max(2_000, maximumChunkCharacters)
    }

    func summarize(
        title: String,
        segments: [TranscriptSegment],
        configuration: SummaryConfiguration
    ) async throws -> String {
        guard !segments.isEmpty else { throw RemoteModelError.emptyResult }
        let lines = segments.map { segment in
            "[\(Self.timestamp(segment.startTime))][\(segment.source.title)] \(segment.normalizedText ?? segment.text)"
        }
        let chunks = Self.chunk(lines, maximumCharacters: maximumChunkCharacters)
        if chunks.count == 1 {
            return try await requestSummary(
                systemPrompt: configuration.prompt,
                userContent: "会议名称：\(title)\n\n以下是会议逐字稿：\n\n\(chunks[0])",
                configuration: configuration
            )
        }

        var partials: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partial = try await requestSummary(
                systemPrompt: "你正在处理长会议的第 \(index + 1)/\(chunks.count) 段。只提取事实、结论、待办、风险和关键时间点，不得编造；控制在 1200 字以内。",
                userContent: "会议名称：\(title)\n\n本段逐字稿：\n\n\(chunk)",
                configuration: configuration
            )
            partials.append(String(partial.prefix(4_000)))
        }

        return try await requestSummary(
            systemPrompt: configuration.prompt,
            userContent: "会议名称：\(title)\n\n以下是按时间顺序生成的阶段摘要，请去重并生成最终会议纪要：\n\n\(partials.enumerated().map { "## 阶段 \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n"))",
            configuration: configuration
        )
    }

    private func requestSummary(
        systemPrompt: String,
        userContent: String,
        configuration: SummaryConfiguration
    ) async throws -> String {
        let payload = ChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userContent)
            ],
            temperature: 0.2,
            stream: false
        )
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        APIRequestAuthentication.apply(apiKey: configuration.apiKey, endpoint: configuration.endpoint, to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let raw = (try? JSONDecoder().decode(SummaryErrorEnvelope.self, from: data).error.message)
                ?? String(String(data: data, encoding: .utf8)?.prefix(240) ?? "未知错误")
            throw RemoteModelError.server(status: httpResponse.statusCode, message: raw)
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        let markdown = result.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !markdown.isEmpty else { throw RemoteModelError.emptyResult }
        return markdown
    }

    private static func chunk(_ lines: [String], maximumCharacters: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in lines {
            if !current.isEmpty, current.count + line.count + 1 > maximumCharacters {
                chunks.append(current)
                current = ""
            }
            if line.count > maximumCharacters {
                var remaining = line[...]
                while remaining.count > maximumCharacters {
                    let end = remaining.index(remaining.startIndex, offsetBy: maximumCharacters)
                    if !current.isEmpty { chunks.append(current); current = "" }
                    chunks.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
                current = String(remaining)
            } else {
                current += current.isEmpty ? line : "\n\(line)"
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct ChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
}

private struct SummaryErrorEnvelope: Decodable {
    let error: Detail
    struct Detail: Decodable { let message: String }
}
