@preconcurrency import AVFoundation
import Foundation

final class WAVChunkWriter: @unchecked Sendable {
    static let sampleRate = 16_000.0

    let url: URL
    private(set) var frameCount: AVAudioFramePosition = 0
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: "\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    var duration: TimeInterval { Double(frameCount) / Self.sampleRate }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { return }
        let destinationFormat = file.processingFormat
        let converted: AVAudioPCMBuffer
        if buffer.format == destinationFormat {
            converted = buffer
        } else {
            if converter == nil || inputFormat != buffer.format {
                guard let newConverter = AVAudioConverter(from: buffer.format, to: destinationFormat) else {
                    throw AudioCaptureError.invalidAudioFormat
                }
                converter = newConverter
                inputFormat = buffer.format
            }
            guard let converter else { throw AudioCaptureError.invalidAudioFormat }
            let ratio = destinationFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity) else {
                throw AudioCaptureError.cannotCreateAudioBuffer
            }
            let state = WAVConversionInput(buffer: buffer)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if state.supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                state.supplied = true
                inputStatus.pointee = .haveData
                return state.buffer
            }
            if let error { throw error }
            guard status != .error else { throw AudioCaptureError.invalidAudioFormat }
            converted = output
        }
        if converted.frameLength > 0 {
            try file.write(from: converted)
            frameCount += AVAudioFramePosition(converted.frameLength)
        }
    }

    func close() {
        file = nil
        converter = nil
    }

    static func readTail(from url: URL, duration: TimeInterval) throws -> AVAudioPCMBuffer? {
        guard duration > 0 else { return nil }
        let reader = try AVAudioFile(forReading: url)
        let requestedFrames = AVAudioFramePosition(duration * reader.processingFormat.sampleRate)
        let frameCount = min(reader.length, requestedFrames)
        guard frameCount > 0 else { return nil }
        reader.framePosition = reader.length - frameCount
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: reader.processingFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw AudioCaptureError.cannotCreateAudioBuffer
        }
        try reader.read(into: buffer, frameCount: AVAudioFrameCount(frameCount))
        return buffer
    }
}

private final class WAVConversionInput: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
