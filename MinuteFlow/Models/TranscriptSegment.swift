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

enum TranscriptBoundaryReason: String, Codable, Sendable {
    case naturalPause
    case lowEnergyHardLimit
    case forcedHardLimit
    case recordingStopped
    case userPause
    case sourceInterrupted
    case legacyUnknown
}

struct TranscriptRecognitionFragment: Codable, Equatable, Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let originalText: String
    let boundaryReason: TranscriptBoundaryReason
    let overlapBefore: TimeInterval
    var speakerID: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        originalText: String,
        boundaryReason: TranscriptBoundaryReason,
        overlapBefore: TimeInterval = 0,
        speakerID: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.originalText = originalText
        self.boundaryReason = boundaryReason
        self.overlapBefore = overlapBefore
        self.speakerID = speakerID
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
    /// Immutable ASR responses used to assemble this display paragraph. Optional
    /// so transcript files written by MinuteFlow 0.6 and earlier remain readable.
    var recognitionFragments: [TranscriptRecognitionFragment]?
    var boundaryReason: TranscriptBoundaryReason?
    /// Stable local label such as "speaker-1". Display names are stored on the
    /// meeting so users can rename speakers without rewriting transcript text.
    var speakerID: String?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        source: TranscriptSource,
        isFinal: Bool,
        confidence: Float? = nil,
        originalText: String? = nil,
        recognitionFragments: [TranscriptRecognitionFragment]? = nil,
        boundaryReason: TranscriptBoundaryReason? = nil,
        speakerID: String? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.originalText = originalText ?? text
        self.normalizedText = nil
        self.source = source
        self.isFinal = isFinal
        self.confidence = confidence
        self.recognitionFragments = recognitionFragments
        self.boundaryReason = boundaryReason
        self.speakerID = speakerID
    }
}
