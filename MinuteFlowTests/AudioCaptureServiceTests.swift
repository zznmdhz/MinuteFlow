import AVFoundation
import XCTest
@testable import MinuteFlow

final class AudioCaptureServiceTests: XCTestCase {
    func testSilenceProducesZeroLevel() {
        let samples = [Float](repeating: 0, count: 128)
        let level = samples.withUnsafeBufferPointer {
            AudioLevelMeter.normalizedLevel(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertEqual(level, 0, accuracy: 0.001)
    }

    func testAudibleSignalProducesVisibleLevel() {
        let samples = [Float](repeating: 0.5, count: 128)
        let level = samples.withUnsafeBufferPointer {
            AudioLevelMeter.normalizedLevel(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertGreaterThan(level, 0.8)
        XCTAssertLessThanOrEqual(level, 1)
    }

    func testWAVChunkWriterConvertsToSixteenKilohertzMono() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowWAVTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.05) * 0.2
            }
        }

        let writer = try WAVChunkWriter(directory: directory)
        try writer.append(buffer)
        let url = writer.url
        writer.close()

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, accuracy: 1)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 1_200)
    }
}
