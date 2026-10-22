import Foundation

/// SSE framing and Chat Completions deltas, independent of network chunk and
/// UTF-8 boundaries. The transport preserves blank SSE frame delimiters.
struct ASRStreamDecoder {
    private var dataLines: [String] = []
    private var eventBytes = 0
    private(set) var text = ""
    private(set) var completed = false

    mutating func consume(_ line: String) throws -> String? {
        guard !completed else { return nil }
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            eventBytes = 0
            if payload == "[DONE]" { completed = true; return text }
            guard let object = try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
                  object["error"] == nil else { throw RemoteModelError.invalidResponse }
            guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else { return nil }
            if let reason = first["finish_reason"] as? String {
                guard reason == "stop" else { throw RemoteModelError.invalidResponse }
                completed = true
            }
            let delta = first["delta"] as? [String: Any]
            if let content = delta?["content"] as? String { text += content }
            guard text.utf8.count <= 2_000_000 else { throw RemoteModelError.invalidResponse }
            return text.isEmpty ? nil : text
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            eventBytes += value.utf8.count
            guard eventBytes <= 1_000_000 else { throw RemoteModelError.invalidResponse }
            dataLines.append(value)
        }
        return nil
    }
}
