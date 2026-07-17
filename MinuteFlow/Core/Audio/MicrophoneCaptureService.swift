import AVFoundation
import Foundation

final class MicrophoneCaptureService: AudioCaptureService, @unchecked Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    var displayName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "默认麦克风"
    }

    private let engine = AVAudioEngine()
    private let stateLock = NSLock()
    private var writer: AudioFileWriter?
    private var paused = false
    private var tapInstalled = false

    func start(outputURL: URL) async throws {
        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioCaptureError.microphoneUnavailable
        }

        let newWriter = try AudioFileWriter(url: outputURL, channelCount: format.channelCount)
        stateLock.withLock {
            writer = newWriter
            paused = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            stateLock.withLock {
                writer?.close()
                writer = nil
            }
            throw error
        }
    }

    func pause() {
        stateLock.withLock { paused = true }
    }

    func resume() {
        stateLock.withLock { paused = false }
    }

    func stop() async {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        stateLock.withLock {
            writer?.close()
            writer = nil
            paused = false
        }
        onLevelUpdate?(0)
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let (shouldWrite, activeWriter) = stateLock.withLock { (!paused, writer) }
        guard shouldWrite, let activeWriter else { return }

        do {
            try activeWriter.write(buffer)
            onLevelUpdate?(AudioLevelMeter.normalizedLevel(for: buffer))
            onAudioBuffer?(CapturedAudioBuffer(buffer: buffer, source: .microphone))
        } catch {
            onError?(error)
        }
    }
}
