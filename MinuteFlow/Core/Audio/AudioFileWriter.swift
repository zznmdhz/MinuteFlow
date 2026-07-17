@preconcurrency import AVFoundation
import Foundation

private final class ConversionInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

final class AudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init(url: URL, channelCount: AVAudioChannelCount) throws {
        let channels = max(1, min(channelCount, 2))
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(_ inputBuffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let audioFile else { return }

        let destinationFormat = audioFile.processingFormat
        if inputBuffer.format == destinationFormat {
            try audioFile.write(from: inputBuffer)
            return
        }

        let converter = try converter(for: inputBuffer.format, destinationFormat: destinationFormat)
        let ratio = destinationFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: destinationFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioCaptureError.cannotCreateAudioBuffer
        }

        let inputState = ConversionInputState(buffer: inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if inputState.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputState.supplied = true
            inputStatus.pointee = .haveData
            return inputState.buffer
        }

        if let conversionError { throw conversionError }
        guard status != .error else { throw AudioCaptureError.invalidAudioFormat }
        if outputBuffer.frameLength > 0 {
            try audioFile.write(from: outputBuffer)
        }
    }

    func close() {
        lock.lock()
        audioFile = nil
        converter = nil
        converterInputFormat = nil
        lock.unlock()
    }

    private func converter(
        for inputFormat: AVAudioFormat,
        destinationFormat: AVAudioFormat
    ) throws -> AVAudioConverter {
        if let converter, converterInputFormat == inputFormat {
            return converter
        }
        guard let newConverter = AVAudioConverter(from: inputFormat, to: destinationFormat) else {
            throw AudioCaptureError.invalidAudioFormat
        }
        converter = newConverter
        converterInputFormat = inputFormat
        return newConverter
    }
}
