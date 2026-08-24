@preconcurrency import AVFoundation
import Foundation

struct PostTranscriptionProgress: Sendable, Equatable {
    let completedTime: TimeInterval
    let totalTime: TimeInterval
    let completedChunks: Int
    let totalChunks: Int

    var fraction: Double {
        guard totalTime > 0 else { return 0 }
        return min(1, max(0, completedTime / totalTime))
    }
}

protocol PostRecordingTranscribing: Sendable {
    func transcribe(
        audioURL: URL,
        sessionID: UUID,
        source: TranscriptSource,
        startingAt: TimeInterval,
        configuration: ASRConfiguration,
        maximumChunkDuration: TimeInterval,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onProgress: @escaping @Sendable (PostTranscriptionProgress) -> Void
    ) async throws
}

final class PostRecordingTranscriptionService: PostRecordingTranscribing, @unchecked Sendable {
    private let client: any ASRClient

    init(client: any ASRClient = RemoteASRClient()) {
        self.client = client
    }

    func transcribe(
        audioURL: URL,
        sessionID: UUID,
        source: TranscriptSource,
        startingAt: TimeInterval,
        configuration: ASRConfiguration,
        maximumChunkDuration: TimeInterval,
        onSegment: @escaping @Sendable (TranscriptSegment) -> Void,
        onProgress: @escaping @Sendable (PostTranscriptionProgress) -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "MinuteFlow-Post-ASR-\(sessionID.uuidString)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let chunks = try await Task.detached(priority: .userInitiated) {
            try OfflineAudioChunker.makeChunks(
                audioURL: audioURL,
                directory: directory,
                startingAt: max(0, startingAt),
                maximumChunkDuration: min(max(maximumChunkDuration, 10), 30)
            )
        }.value
        guard !chunks.isEmpty else { throw PostTranscriptionError.noAudibleSpeech }

        let totalTime = chunks.last?.endTime ?? startingAt
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let text = try await transcribeWithRetry(chunk.url, configuration: configuration)
            try Task.checkCancellation()
            let fragment = TranscriptRecognitionFragment(
                startTime: chunk.startTime,
                endTime: chunk.endTime,
                originalText: text,
                boundaryReason: chunk.boundaryReason
            )
            onSegment(
                TranscriptSegment(
                    startTime: chunk.startTime,
                    endTime: chunk.endTime,
                    text: text,
                    source: source,
                    isFinal: true,
                    originalText: text,
                    recognitionFragments: [fragment],
                    boundaryReason: chunk.boundaryReason
                )
            )
            try? FileManager.default.removeItem(at: chunk.url)
            onProgress(
                PostTranscriptionProgress(
                    completedTime: chunk.endTime,
                    totalTime: totalTime,
                    completedChunks: index + 1,
                    totalChunks: chunks.count
                )
            )
        }
    }

    private func transcribeWithRetry(
        _ url: URL,
        configuration: ASRConfiguration
    ) async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await client.transcribe(wavURL: url, configuration: configuration)
            } catch {
                lastError = error
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
        throw lastError ?? RemoteModelError.invalidResponse
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let remote = error as? RemoteModelError,
           case .server(let status, _) = remote {
            return status == 408 || status == 429 || (500...599).contains(status)
        }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost]
                .contains(urlError.code)
        }
        return false
    }
}

private struct OfflineAudioChunk: Sendable {
    let url: URL
    let startTime: TimeInterval
    let endTime: TimeInterval
    let boundaryReason: TranscriptBoundaryReason
}

private enum OfflineAudioChunker {
    static func makeChunks(
        audioURL: URL,
        directory: URL,
        startingAt: TimeInterval,
        maximumChunkDuration: TimeInterval
    ) throws -> [OfflineAudioChunk] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = try AVAudioFile(forReading: audioURL)
        let format = input.processingFormat
        guard format.sampleRate > 0 else { throw PostTranscriptionError.invalidAudio }

        let totalDuration = Double(input.length) / format.sampleRate
        guard startingAt < totalDuration else { return [] }
        input.framePosition = min(
            input.length,
            AVAudioFramePosition((startingAt * format.sampleRate).rounded(.down))
        )

        let frameCapacity: AVAudioFrameCount = 4_096
        var writer = try WAVChunkWriter(directory: directory)
        var writerStart = startingAt
        var voiceActivity = AdaptiveVoiceActivityDetector()
        var hasSpeech = false
        var speechStartInWriter: TimeInterval?
        var trailingSilence: TimeInterval = 0
        var chunks: [OfflineAudioChunk] = []

        func rotate(
            boundary: TranscriptBoundaryReason?,
            continuingSpeech: Bool
        ) throws {
            let duration = writer.duration
            let oldURL = writer.url
            writer.close()
            if let boundary, hasSpeech, duration > 0.25 {
                chunks.append(
                    OfflineAudioChunk(
                        url: oldURL,
                        startTime: writerStart,
                        endTime: writerStart + duration,
                        boundaryReason: boundary
                    )
                )
            } else {
                try? FileManager.default.removeItem(at: oldURL)
            }
            writerStart += duration
            writer = try WAVChunkWriter(directory: directory)
            hasSpeech = continuingSpeech
            speechStartInWriter = continuingSpeech ? 0 : nil
            trailingSilence = 0
            voiceActivity.reset(continuingSpeech: continuingSpeech)
        }

        while input.framePosition < input.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                throw PostTranscriptionError.invalidAudio
            }
            try input.read(into: buffer, frameCount: frameCapacity)
            guard buffer.frameLength > 0 else { break }
            try writer.append(buffer)

            let duration = Double(buffer.frameLength) / format.sampleRate
            let level = AudioLevelMeter.normalizedLevel(for: buffer)
            let observation = voiceActivity.observe(level: level, duration: duration)
            trailingSilence = observation.trailingSilence
            if observation.speechStarted, !hasSpeech {
                hasSpeech = true
                speechStartInWriter = max(0, writer.duration - duration)
            }

            let activeDuration = speechStartInWriter.map { max(0, writer.duration - $0) } ?? 0
            if hasSpeech, activeDuration >= 0.8, trailingSilence >= 0.7 {
                try rotate(boundary: .naturalPause, continuingSpeech: false)
            } else if hasSpeech, activeDuration >= maximumChunkDuration {
                try rotate(boundary: .forcedHardLimit, continuingSpeech: true)
            } else if !hasSpeech, writer.duration >= 3 {
                try rotate(boundary: nil, continuingSpeech: false)
            }
        }

        if hasSpeech, writer.duration > 0.25 {
            try rotate(boundary: .recordingStopped, continuingSpeech: false)
        } else {
            writer.close()
            try? FileManager.default.removeItem(at: writer.url)
        }
        return chunks
    }
}

enum PostTranscriptionError: LocalizedError {
    case invalidAudio
    case noAudibleSpeech
    case noSavedAudio

    var errorDescription: String? {
        switch self {
        case .invalidAudio: "无法读取这条会议的录音格式。"
        case .noAudibleSpeech: "录音中没有检测到足够清晰的语音。"
        case .noSavedAudio: "没有找到可用于事后转写的录音文件。"
        }
    }
}
