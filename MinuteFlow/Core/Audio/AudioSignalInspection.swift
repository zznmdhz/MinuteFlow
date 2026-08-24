@preconcurrency import AVFoundation
import Foundation

struct AudioSignalReport: Equatable, Sendable {
    let rmsDB: Float
    let peakDB: Float
    let duration: TimeInterval

    var hasAudibleSignal: Bool {
        duration > 0.25 && peakDB > -65 && rmsDB > -75
    }
}

enum AudioSignalInspector {
    static func inspect(_ url: URL) async -> AudioSignalReport? {
        await Task.detached(priority: .utility) { inspectSynchronously(url) }.value
    }

    private static func inspectSynchronously(_ url: URL) -> AudioSignalReport? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_768)
        else { return nil }
        var sumSquares: Double = 0
        var sampleCount: Int64 = 0
        var peak: Float = 0
        while true {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: buffer.frameCapacity)) != nil,
                  buffer.frameLength > 0,
                  let channels = buffer.floatChannelData
            else { break }
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<Int(buffer.frameLength) {
                    let value = channels[channel][index]
                    sumSquares += Double(value * value)
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            }
        }
        guard sampleCount > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(sampleCount))
        let rmsDB = Float(20 * log10(max(rms, 1e-9)))
        let peakDB = 20 * log10(max(peak, 1e-9))
        return AudioSignalReport(
            rmsDB: rmsDB,
            peakDB: peakDB,
            duration: Double(file.length) / format.sampleRate
        )
    }
}
