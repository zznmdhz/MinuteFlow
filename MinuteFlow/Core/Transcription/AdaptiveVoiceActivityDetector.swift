import Foundation

struct VoiceActivityObservation: Equatable, Sendable {
    let isSpeech: Bool
    let speechStarted: Bool
    let trailingSilence: TimeInterval
    let noiseFloor: Float
    let enterThreshold: Float
    let exitThreshold: Float
}

/// A level-based VAD gate designed for live chunking. Unlike the previous
/// one-shot noise estimate, the lower part of a rolling level distribution is
/// followed throughout the recording. Hysteresis prevents short consonants or
/// room noise from repeatedly opening and closing a paragraph.
struct AdaptiveVoiceActivityDetector: Sendable {
    private struct LevelSample: Sendable {
        let level: Float
        let duration: TimeInterval
    }

    private var samples: [LevelSample] = []
    private var sampleDuration: TimeInterval = 0
    private var candidateSpeechDuration: TimeInterval = 0
    private(set) var isSpeech = false
    private(set) var trailingSilence: TimeInterval = 0
    private(set) var noiseFloor: Float = 0

    private let historyDuration: TimeInterval
    private let maximumNoiseFloor: Float
    private let enterMargin: Float
    private let exitMargin: Float

    init(
        historyDuration: TimeInterval = 6,
        maximumNoiseFloor: Float = 0.42,
        enterMargin: Float = 0.10,
        exitMargin: Float = 0.06
    ) {
        self.historyDuration = max(1, historyDuration)
        self.maximumNoiseFloor = min(max(maximumNoiseFloor, 0.2), 0.6)
        self.enterMargin = min(max(enterMargin, 0.05), 0.25)
        self.exitMargin = min(max(exitMargin, 0.03), enterMargin)
    }

    mutating func observe(level rawLevel: Float, duration: TimeInterval) -> VoiceActivityObservation {
        let level = min(max(rawLevel, 0), 1)
        let duration = max(0, duration)
        samples.append(LevelSample(level: level, duration: duration))
        sampleDuration += duration
        while sampleDuration > historyDuration, samples.count > 1 {
            sampleDuration -= samples.removeFirst().duration
        }

        let ordered = samples.map(\.level).sorted()
        if !ordered.isEmpty {
            let percentileIndex = min(ordered.count - 1, Int(Double(ordered.count - 1) * 0.20))
            let rollingLow = ordered[percentileIndex]
            // A recording can begin while somebody is already talking. Until
            // several capture callbacks are available, treating the first
            // loud buffer as the room baseline would make speech impossible
            // to enter (threshold = first buffer + margin).
            let startupCeiling: Float = samples.count < 6 ? 0.30 : maximumNoiseFloor
            noiseFloor = min(startupCeiling, rollingLow)
        }

        let enterThreshold = min(0.72, max(0.12, noiseFloor + enterMargin))
        let exitThreshold = min(enterThreshold - 0.02, max(0.08, noiseFloor + exitMargin))
        let wasSpeech = isSpeech

        if isSpeech {
            if level >= exitThreshold {
                trailingSilence = 0
            } else {
                trailingSilence += duration
            }
        } else if level >= enterThreshold {
            candidateSpeechDuration += duration
            if candidateSpeechDuration >= 0.12 {
                isSpeech = true
                trailingSilence = 0
            }
        } else {
            candidateSpeechDuration = 0
            trailingSilence = 0
        }

        return VoiceActivityObservation(
            isSpeech: isSpeech,
            speechStarted: !wasSpeech && isSpeech,
            trailingSilence: trailingSilence,
            noiseFloor: noiseFloor,
            enterThreshold: enterThreshold,
            exitThreshold: exitThreshold
        )
    }

    mutating func reset(continuingSpeech: Bool) {
        candidateSpeechDuration = 0
        trailingSilence = 0
        isSpeech = continuingSpeech
    }
}
