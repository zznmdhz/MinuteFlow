import AVFoundation

enum AudioLevelMeter {
    static func normalizedLevel(samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    static func normalizedLevel(for buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        return normalizedLevel(samples: channels[0], count: Int(buffer.frameLength))
    }
}

