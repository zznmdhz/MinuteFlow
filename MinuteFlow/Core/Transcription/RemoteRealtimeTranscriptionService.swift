import Foundation

final class RemoteRealtimeTranscriptionService: @unchecked Sendable {
    var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.minuteflow.remote-asr", qos: .userInitiated)
    private let uploadGroup = DispatchGroup()
    private let client = RemoteASRClient()
    private let resultsLock = NSLock()
    private var maximumChunkDuration: TimeInterval = 3
    private let minimumChunkDuration: TimeInterval = 0.8
    private let silenceToFlush: TimeInterval = 0.7
    private let speechLevelThreshold: Float = 0.1
    private var configuration: ASRConfiguration?
    private var accumulators: [TranscriptSource: ChunkAccumulator] = [:]
    private var running = false
    private var completedSegments: [TranscriptSegment] = []

    init() {}

    func start(
        sources: Set<TranscriptSource>,
        configuration: ASRConfiguration,
        maximumChunkDuration: TimeInterval
    ) throws {
        let directory = Self.temporaryDirectory()
        try queue.sync {
            self.configuration = configuration
            self.maximumChunkDuration = min(max(maximumChunkDuration, 2), 8)
            accumulators = [:]
            resultsLock.withLock { completedSegments = [] }
            for source in sources {
                accumulators[source] = try ChunkAccumulator(source: source, directory: directory)
            }
            running = true
        }
        onStatus?("动态转写已启动 · 最长 \(Int(self.maximumChunkDuration)) 秒")
    }

    func append(_ packet: CapturedAudioBuffer) {
        queue.async { [weak self] in
            guard let self, self.running, let accumulator = self.accumulators[packet.source] else { return }
            do {
                try accumulator.writer.append(packet.buffer)
                let inputDuration = packet.buffer.format.sampleRate > 0
                    ? Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
                    : 0
                let level = AudioLevelMeter.normalizedLevel(for: packet.buffer)
                if level >= self.speechLevelThreshold {
                    accumulator.hasSpeech = true
                    accumulator.trailingSilence = 0
                } else if accumulator.hasSpeech {
                    accumulator.trailingSilence += inputDuration
                }

                let shouldFlushForSilence = accumulator.hasSpeech
                    && accumulator.writer.duration >= self.minimumChunkDuration
                    && accumulator.trailingSilence >= self.silenceToFlush
                let reachedMaximum = accumulator.writer.duration >= self.maximumChunkDuration

                if shouldFlushForSilence || (reachedMaximum && accumulator.hasSpeech) {
                    try self.flush(accumulator)
                } else if reachedMaximum && !accumulator.hasSpeech {
                    try self.discardSilentChunk(accumulator)
                }
            } catch {
                self.onError?(error)
            }
        }
    }

    func finish() async -> [TranscriptSegment] {
        queue.sync {
            running = false
            for accumulator in accumulators.values {
                if accumulator.hasSpeech, accumulator.writer.duration > 0.25 {
                    try? flush(accumulator)
                } else {
                    accumulator.writer.close()
                    try? FileManager.default.removeItem(at: accumulator.writer.url)
                }
            }
            accumulators.removeAll()
        }

        await withCheckedContinuation { continuation in
            uploadGroup.notify(queue: queue) { continuation.resume() }
        }
        onStatus?("转写完成")
        return resultsLock.withLock { completedSegments.sorted { $0.startTime < $1.startTime } }
    }

    private func flush(_ accumulator: ChunkAccumulator) throws {
        guard let configuration else { return }
        let oldWriter = accumulator.writer
        let duration = oldWriter.duration
        let startTime = accumulator.nextStartTime
        oldWriter.close()
        accumulator.nextStartTime += duration
        accumulator.writer = try WAVChunkWriter(directory: Self.temporaryDirectory())
        accumulator.hasSpeech = false
        accumulator.trailingSilence = 0

        uploadGroup.enter()
        onStatus?("正在识别 \(Int(startTime))–\(Int(startTime + duration)) 秒…")
        Task { [weak self] in
            defer {
                try? FileManager.default.removeItem(at: oldWriter.url)
                self?.uploadGroup.leave()
            }
            guard let self else { return }
            do {
                let text = try await client.transcribe(wavURL: oldWriter.url, configuration: configuration)
                let segment = TranscriptSegment(
                    startTime: startTime,
                    endTime: startTime + duration,
                    text: text,
                    source: accumulator.source,
                    isFinal: true
                )
                self.resultsLock.withLock { self.completedSegments.append(segment) }
                self.onSegment?(segment)
                self.onStatus?("已识别至 \(Int(startTime + duration)) 秒，等待下一段…")
            } catch {
                self.onError?(error)
            }
        }
    }

    private func discardSilentChunk(_ accumulator: ChunkAccumulator) throws {
        let duration = accumulator.writer.duration
        let oldURL = accumulator.writer.url
        accumulator.writer.close()
        try? FileManager.default.removeItem(at: oldURL)
        accumulator.nextStartTime += duration
        accumulator.writer = try WAVChunkWriter(directory: Self.temporaryDirectory())
        accumulator.hasSpeech = false
        accumulator.trailingSilence = 0
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ASR", directoryHint: .isDirectory)
    }
}

private final class ChunkAccumulator: @unchecked Sendable {
    let source: TranscriptSource
    var writer: WAVChunkWriter
    var nextStartTime: TimeInterval = 0
    var hasSpeech = false
    var trailingSilence: TimeInterval = 0

    init(source: TranscriptSource, directory: URL) throws {
        self.source = source
        writer = try WAVChunkWriter(directory: directory)
    }
}
