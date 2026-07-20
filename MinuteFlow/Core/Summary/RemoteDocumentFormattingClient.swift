import Foundation

struct DocumentFormattingConfiguration: Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
}

protocol DocumentFormattingClient: Sendable {
    func format(
        title: String,
        segments: [TranscriptSegment],
        configuration: DocumentFormattingConfiguration
    ) async throws -> String
}

/// Turns a transcript into a readable Markdown document without collapsing it
/// into a summary. Long meetings are formatted in order, chunk by chunk, so the
/// model is never asked to discard earlier details to fit a single response.
struct RemoteDocumentFormattingClient: DocumentFormattingClient, Sendable {
    private let session: URLSession
    private let maximumChunkCharacters: Int

    init(session: URLSession = .shared, maximumChunkCharacters: Int = 18_000) {
        self.session = session
        self.maximumChunkCharacters = max(2_000, maximumChunkCharacters)
    }

    func format(
        title: String,
        segments: [TranscriptSegment],
        configuration: DocumentFormattingConfiguration
    ) async throws -> String {
        guard !segments.isEmpty else { throw RemoteModelError.emptyResult }
        let lines = segments.map { segment in
            "[\(Self.timestamp(segment.startTime))][\(segment.source.title)] \(segment.normalizedText ?? segment.text)"
        }
        let chunks = Self.chunk(lines, maximumCharacters: maximumChunkCharacters)
        var sections: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let result = try await request(
                content: """
                文档名称：\(title)
                当前部分：\(index + 1)/\(chunks.count)

                请整理下面这部分逐字稿：

                \(chunk)
                """,
                configuration: configuration
            )
            sections.append(Self.removingCodeFence(from: result))
        }

        let safeTitle = title.replacingOccurrences(of: "\n", with: " ")
        return "# \(safeTitle)\n\n> AI 整理文稿 · 内容来自 MinuteFlow 逐字稿，请结合原始录音复核重要信息。\n\n"
            + sections.joined(separator: "\n\n---\n\n")
    }

    private func request(
        content: String,
        configuration: DocumentFormattingConfiguration
    ) async throws -> String {
        let payload = DocumentChatRequest(
            model: configuration.model,
            messages: [
                .init(
                    role: "system",
                    content: """
                    你是一名严谨的文档编辑。把逐字稿整理成易读的 Markdown 正文：
                    - 保留事实、数字、结论、问题和上下文，不做摘要，不补充逐字稿中没有的信息；
                    - 修正明显的标点、断句、口头赘词和相邻重复，但不得改变原意；
                    - 按内容主题设置二级或三级标题，并合并成自然段；
                    - 只有区分发言来源确有帮助时才保留“系统声音/麦克风”标签；
                    - 保持原文主要语言；仅输出 Markdown 正文，不输出一级标题，不使用代码围栏。
                    """
                ),
                .init(role: "user", content: content)
            ],
            temperature: 0.15,
            stream: false
        )
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        APIRequestAuthentication.apply(apiKey: configuration.apiKey, endpoint: configuration.endpoint, to: &request)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let raw = (try? JSONDecoder().decode(DocumentErrorEnvelope.self, from: data).error.message)
                ?? String(String(data: data, encoding: .utf8)?.prefix(240) ?? "未知错误")
            throw RemoteModelError.server(status: httpResponse.statusCode, message: raw)
        }
        let result = try JSONDecoder().decode(DocumentChatResponse.self, from: data)
        let markdown = result.choices.first?.message.content
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        return chunks
    }

    private static func removingCodeFence(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return trimmed }
        let start = lines.index(after: lines.startIndex)
        let end = lines.last == "```" ? lines.index(before: lines.endIndex) : lines.endIndex
        return lines[start..<end].joined(separator: "\n")
    }

    private static func timestamp(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
    }
}

private struct DocumentChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let temperature: Double
    let stream: Bool

    struct Message: Encodable {
        let role: String
        let content: String
    }
}

private struct DocumentChatResponse: Decodable {
    let choices: [Choice]
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
}

private struct DocumentErrorEnvelope: Decodable {
    let error: Detail
    struct Detail: Decodable { let message: String }
}
