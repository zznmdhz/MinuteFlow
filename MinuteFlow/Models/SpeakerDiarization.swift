import Foundation

struct SpeakerTurn: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var speakerID: String
    var confidence: Float

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        speakerID: String,
        confidence: Float
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.speakerID = speakerID
        self.confidence = confidence
    }
}

struct SpeakerDiarizationResult: Codable, Equatable, Sendable {
    let version: Int
    let generatedAt: Date
    let sourceFileName: String
    let method: String
    let speakerCount: Int
    let turns: [SpeakerTurn]
}

enum SpeakerDiarizationError: LocalizedError, Sendable {
    case unreadableAudio
    case noSpeechDetected
    case insufficientSpeech

    var errorDescription: String? {
        switch self {
        case .unreadableAudio: "无法读取录音，不能分析说话人。"
        case .noSpeechDetected: "录音中没有检测到足够清晰的语音。"
        case .insufficientSpeech: "有效讲话时间太短，暂时无法可靠地区分说话人。"
        }
    }
}
