import Foundation

struct SummaryConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
    let prompt: String
}

struct RemoteSummaryClient: Sendable {
    func summarize(
        title: String,
        segments: [TranscriptSegment],
        configuration: SummaryConfiguration
    ) async throws -> String {
        guard !segments.isEmpty else { throw RemoteModelError.emptyResult }
        let transcript = segments.map { segment in
            "[\(Self.timestamp(segment.startTime))][\(segment.source.title)] \(segment.text)"
        }.joined(separator: "\n")

        let payload = ChatRequest(
            model: configuration.model,
            messages: [
                .init(role: "system", content: configuration.prompt),
                .init(
                    role: "user",
                    content: "会议名称：\(title)\n\n以下是会议逐字稿：\n\n\(transcript)"
                )
            ],
            temperature: 0.2,
            stream: false
        )

        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 180)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "未知错误"
            throw RemoteModelError.server(status: httpResponse.statusCode, message: raw)
        }
        let result = try JSONDecoder().decode(ChatResponse.self, from: data)
        let markdown = result.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !markdown.isEmpty else { throw RemoteModelError.emptyResult }
        return markdown
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

