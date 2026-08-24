@preconcurrency import AVFoundation
import Foundation

struct AudioTimelineEpoch: Codable, Equatable, Sendable {
    /// Frame position in the already-normalized source recording.
    let sourceStartFrame: Int64
    let frameCount: Int64
    /// Destination position on the active meeting timeline.
    let logicalStartFrame: Int64
    let timestampQuality: AudioCaptureTimestampQuality

    init(
        sourceStartFrame: Int64,
        frameCount: Int64,
        logicalStartFrame: Int64,
        timestampQuality: AudioCaptureTimestampQuality = .captureClock
    ) {
        self.sourceStartFrame = sourceStartFrame
        self.frameCount = frameCount
        self.logicalStartFrame = logicalStartFrame
        self.timestampQuality = timestampQuality
    }
}

struct AudioMixTrackManifest: Codable, Equatable, Sendable {
    let source: TranscriptSource
    let relativePath: String
    let channelCount: Int
    let epochs: [AudioTimelineEpoch]
}

struct AudioMixTimelineManifest: Codable, Equatable, Sendable {
    let version: Int
    let timelineSampleRate: Double
    let logicalDurationFrames: Int64
    let tracks: [AudioMixTrackManifest]

    init(
        version: Int = 1,
        timelineSampleRate: Double = 48_000,
        logicalDurationFrames: Int64,
        tracks: [AudioMixTrackManifest]
    ) {
        self.version = version
        self.timelineSampleRate = timelineSampleRate
        self.logicalDurationFrames = logicalDurationFrames
        self.tracks = tracks
    }
}

struct AudioMixInput: Equatable, Sendable {
    let source: TranscriptSource
    let url: URL
    let timelineOffset: TimeInterval
    let epochs: [AudioTimelineEpoch]

    init(
        source: TranscriptSource,
        url: URL,
        timelineOffset: TimeInterval = 0,
        epochs: [AudioTimelineEpoch] = []
    ) {
        self.source = source
        self.url = url
        self.timelineOffset = timelineOffset
        self.epochs = epochs
    }
}

struct AudioMixRequest: Equatable, Sendable {
    let inputs: [AudioMixInput]
    let outputURL: URL
    let timelineSampleRate: Double
    let expectedDuration: TimeInterval?

    init(
        inputs: [AudioMixInput],
        outputURL: URL,
        timelineSampleRate: Double = 48_000,
        expectedDuration: TimeInterval? = nil
    ) {
        self.inputs = inputs
        self.outputURL = outputURL
        self.timelineSampleRate = timelineSampleRate
        self.expectedDuration = expectedDuration
    }
}

struct AudioMixResult: Equatable, Sendable {
    let outputURL: URL
    let duration: TimeInterval
    let includedSources: [TranscriptSource]
    let peak: Float
    let finalScale: Float
    let degraded: Bool
    let warnings: [String]
}

protocol AudioMixing: Sendable {
    func mix(_ request: AudioMixRequest) async throws -> AudioMixResult
}

enum AudioMixError: LocalizedError, Equatable, Sendable {
    case noReadableInput
    case invalidTimeline
    case outputConflictsWithInput
    case cannotCreateRenderFormat
    case renderStalled
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .noReadableInput:
            "没有可读取的录音来源，无法生成完整录音。"
        case .invalidTimeline:
            "录音时间轴无效，无法安全对齐音频。"
        case .outputConflictsWithInput:
            "完整录音不能覆盖原始分轨。"
        case .cannotCreateRenderFormat:
            "无法创建 48 kHz 双声道混音格式。"
        case .renderStalled:
            "音频渲染未能继续。"
        case .emptyOutput:
            "完整录音没有可播放的音频数据。"
        }
    }
}

/// Offline-only mixer. Original recordings are read without modification and the final M4A is
/// committed atomically only after it can be reopened successfully.
actor AVFoundationOfflineAudioMixer: AudioMixing {
    private let fileManager: FileManager
    private let outputSampleRate: Double = 48_000
    private let maximumFrameCount: AVAudioFrameCount = 4_096
    private let peakCeiling: Float = 0.79 // about -2 dBFS, leaving AAC reconstruction headroom

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func mix(_ request: AudioMixRequest) async throws -> AudioMixResult {
        guard request.timelineSampleRate > 0, request.timelineSampleRate.isFinite else {
            throw AudioMixError.invalidTimeline
        }
        let outputPath = request.outputURL.standardizedFileURL
        guard !request.inputs.contains(where: { $0.url.standardizedFileURL == outputPath }) else {
            throw AudioMixError.outputConflictsWithInput
        }

        try Task.checkCancellation()
        try fileManager.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let jobID = UUID().uuidString
        let dryURL = outputPath.deletingLastPathComponent()
            .appending(path: ".mixed-\(jobID).caf")
        let pendingURL = outputPath.deletingLastPathComponent()
            .appending(path: ".mixed-\(jobID).m4a")
        defer {
            try? fileManager.removeItem(at: dryURL)
            try? fileManager.removeItem(at: pendingURL)
        }

        var warnings: [String] = []
        var prepared: [(input: AudioMixInput, file: AVAudioFile)] = []
        for input in request.inputs {
            do {
                let file = try AVAudioFile(forReading: input.url)
                guard file.length > 0, file.processingFormat.sampleRate > 0 else {
                    warnings.append("\(input.source.title)文件为空，已忽略。")
                    continue
                }
                prepared.append((input, file))
            } catch {
                warnings.append("\(input.source.title)文件不可读取，已忽略：\(error.localizedDescription)")
            }
        }
        guard !prepared.isEmpty else { throw AudioMixError.noReadableInput }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioMixError.cannotCreateRenderFormat
        }

        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: maximumFrameCount
        )

        var players: [AVAudioPlayerNode] = []
        var totalOutputFrames: Int64 = 0
        for item in prepared {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: item.file.processingFormat)
            player.volume = roleVolume(for: item.input.source, sourceCount: prepared.count)
            schedule(item.input, file: item.file, player: player, request: request)
            players.append(player)
            totalOutputFrames = max(
                totalOutputFrames,
                outputEndFrame(for: item.input, file: item.file, request: request)
            )
        }

        if let expectedDuration = request.expectedDuration,
           expectedDuration.isFinite, expectedDuration > 0 {
            totalOutputFrames = max(
                totalOutputFrames,
                Int64((expectedDuration * outputSampleRate).rounded(.up))
            )
        }
        guard totalOutputFrames > 0,
              totalOutputFrames <= Int64(outputSampleRate * 60 * 60 * 24) else {
            throw AudioMixError.invalidTimeline
        }

        engine.prepare()
        try engine.start()
        players.forEach { $0.play() }

        var dryFile: AVAudioFile? = try AVAudioFile(
            forWriting: dryURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw AudioMixError.cannotCreateRenderFormat
        }

        var renderedFrames: Int64 = 0
        var dryPeak: Float = 0
        var stalledAttempts = 0
        while renderedFrames < totalOutputFrames {
            try Task.checkCancellation()
            let requestedFrames = AVAudioFrameCount(
                min(Int64(maximumFrameCount), totalOutputFrames - renderedFrames)
            )
            renderBuffer.frameLength = 0
            let status = try engine.renderOffline(requestedFrames, to: renderBuffer)
            if renderBuffer.frameLength > 0 {
                dryPeak = max(dryPeak, peak(in: renderBuffer))
                try dryFile?.write(from: renderBuffer)
                renderedFrames += Int64(renderBuffer.frameLength)
                stalledAttempts = 0
            } else {
                stalledAttempts += 1
            }

            switch status {
            case .success, .insufficientDataFromInputNode:
                break
            case .cannotDoInCurrentContext:
                stalledAttempts += 1
            case .error:
                throw AudioMixError.renderStalled
            @unknown default:
                throw AudioMixError.renderStalled
            }
            if stalledAttempts > 20 { throw AudioMixError.renderStalled }
        }
        players.forEach { $0.stop() }
        engine.stop()
        dryFile = nil // flush and finalize the PCM container before reopening it

        let finalScale: Float = dryPeak > peakCeiling ? peakCeiling / dryPeak : 1
        let dryInput = try AVAudioFile(forReading: dryURL)
        let writer = try AudioFileWriter(url: pendingURL, channelCount: 2)
        defer { writer.close() }
        guard let encodingBuffer = AVAudioPCMBuffer(
            pcmFormat: dryInput.processingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw AudioMixError.cannotCreateRenderFormat
        }

        while dryInput.framePosition < dryInput.length {
            try Task.checkCancellation()
            encodingBuffer.frameLength = 0
            try dryInput.read(into: encodingBuffer, frameCount: maximumFrameCount)
            guard encodingBuffer.frameLength > 0 else { break }
            apply(scale: finalScale, to: encodingBuffer)
            try writer.write(encodingBuffer)
        }
        writer.close()

        let validationFile = try AVAudioFile(forReading: pendingURL)
        guard validationFile.length > 0, validationFile.processingFormat.channelCount == 2 else {
            throw AudioMixError.emptyOutput
        }
        let duration = Double(validationFile.length) / validationFile.processingFormat.sampleRate

        try Task.checkCancellation()
        if fileManager.fileExists(atPath: outputPath.path) {
            _ = try fileManager.replaceItemAt(outputPath, withItemAt: pendingURL)
        } else {
            try fileManager.moveItem(at: pendingURL, to: outputPath)
        }

        return AudioMixResult(
            outputURL: outputPath,
            duration: duration,
            includedSources: prepared.map(\.input.source),
            peak: dryPeak * finalScale,
            finalScale: finalScale,
            degraded: prepared.count < request.inputs.count || prepared.count < 2,
            warnings: warnings
        )
    }

    private func schedule(
        _ input: AudioMixInput,
        file: AVAudioFile,
        player: AVAudioPlayerNode,
        request: AudioMixRequest
    ) {
        let playerRate = file.processingFormat.sampleRate
        if input.epochs.isEmpty {
            let startTime = AVAudioTime(
                sampleTime: AVAudioFramePosition(max(0, input.timelineOffset) * playerRate),
                atRate: playerRate
            )
            player.scheduleFile(file, at: startTime)
            return
        }

        for epoch in input.epochs where epoch.frameCount > 0 {
            let sourceStart = max(0, epoch.sourceStartFrame)
            let available = max(0, file.length - sourceStart)
            let frameCount = min(epoch.frameCount, available)
            guard frameCount > 0, epoch.logicalStartFrame >= 0 else { continue }
            let logicalSeconds = Double(epoch.logicalStartFrame) / request.timelineSampleRate
            let startTime = AVAudioTime(
                sampleTime: AVAudioFramePosition((logicalSeconds * playerRate).rounded()),
                atRate: playerRate
            )
            player.scheduleSegment(
                file,
                startingFrame: sourceStart,
                frameCount: AVAudioFrameCount(clamping: frameCount),
                at: startTime
            )
        }
    }

    private func outputEndFrame(
        for input: AudioMixInput,
        file: AVAudioFile,
        request: AudioMixRequest
    ) -> Int64 {
        if input.epochs.isEmpty {
            let duration = Double(file.length) / file.processingFormat.sampleRate
            return Int64(((max(0, input.timelineOffset) + duration) * outputSampleRate).rounded(.up))
        }
        return input.epochs.reduce(0) { current, epoch in
            guard epoch.logicalStartFrame >= 0, epoch.frameCount > 0 else { return current }
            let logicalStart = Double(epoch.logicalStartFrame) / request.timelineSampleRate
            let duration = Double(epoch.frameCount) / file.processingFormat.sampleRate
            return max(current, Int64(((logicalStart + duration) * outputSampleRate).rounded(.up)))
        }
    }

    private func roleVolume(for source: TranscriptSource, sourceCount: Int) -> Float {
        guard sourceCount > 1 else { return 1 }
        return switch source {
        case .system: 0.75
        case .microphone: 1
        case .mixed: 1
        }
    }

    private func peak(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        var result: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let values = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                result = max(result, abs(values[frame]))
            }
        }
        return result
    }

    private func apply(scale: Float, to buffer: AVAudioPCMBuffer) {
        guard scale != 1, let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let values = channels[channel]
            for frame in 0..<Int(buffer.frameLength) {
                values[frame] *= scale
            }
        }
    }
}
