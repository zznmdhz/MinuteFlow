import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioCaptureService: NSObject, AudioCaptureService, @unchecked Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)?
    var onAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)?
    var onError: (@Sendable (Error) -> Void)?
    let displayName = "Mac 系统声音"

    private let captureQueue = DispatchQueue(label: "com.minuteflow.system-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var writer: AudioFileWriter?
    private var paused = false

    func start(outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayAvailable
        }

        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let excludedApplications = content.applications.filter {
            $0.bundleIdentifier == currentBundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false

        let newWriter = try AudioFileWriter(url: outputURL, channelCount: 2)
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)

        stateLock.withLock {
            writer = newWriter
            stream = newStream
            paused = false
        }

        do {
            try await newStream.startCapture()
        } catch {
            stateLock.withLock {
                writer?.close()
                writer = nil
                stream = nil
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
        let activeStream = stateLock.withLock { stream }

        if let activeStream {
            try? await activeStream.stopCapture()
        }

        stateLock.withLock {
            writer?.close()
            writer = nil
            stream = nil
            paused = false
        }
        onLevelUpdate?(0)
    }
}

extension SystemAudioCaptureService: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, sampleBuffer.isValid else { return }

        let (shouldWrite, activeWriter) = stateLock.withLock { (!paused, writer) }
        guard shouldWrite, let activeWriter else { return }

        do {
            let buffer = try sampleBuffer.makePCMBuffer()
            try activeWriter.write(buffer)
            onLevelUpdate?(AudioLevelMeter.normalizedLevel(for: buffer))
            onAudioBuffer?(CapturedAudioBuffer(buffer: buffer, source: .system))
        } catch {
            onError?(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError?(error)
    }
}
