import Foundation

enum TranscriptSource: String, Codable, CaseIterable, Sendable {
    case system
    case microphone
    case mixed

    var title: String {
        switch self {
        case .system: "系统声音"
        case .microphone: "麦克风"
        case .mixed: "混合声音"
        }
    }
}

struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var originalText: String?
    var normalizedText: String?
    var source: TranscriptSource
    var isFinal: Bool
    var confidence: Float?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        source: TranscriptSource,
        isFinal: Bool,
        confidence: Float? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.originalText = text
        self.normalizedText = nil
        self.source = source
        self.isFinal = isFinal
        self.confidence = confidence
    }
}
