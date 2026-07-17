import Foundation

final class RemoteRealtimeTranscriptionService: @unchecked Sendable {
    var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.minuteflow.remote-asr", qos: .userInitiated)
    private let uploadGroup = DispatchGroup()
    private let client = RemoteASRClient()
    private let resultsLock = NSLock()
    private let chunkDuration: TimeInterval
    private var configuration: ASRConfiguration?
    private var accumulators: [TranscriptSource: ChunkAccumulator] = [:]
    private var running = false
    private var completedSegments: [TranscriptSegment] = []

    init(chunkDuration: TimeInterval = 10) {
        self.chunkDuration = chunkDuration
    }

    func start(sources: Set<TranscriptSource>, configuration: ASRConfiguration) throws {
        let directory = Self.temporaryDirectory()
        try queue.sync {
            self.configuration = configuration
            accumulators = [:]
            resultsLock.withLock { completedSegments = [] }
            for source in sources {
                accumulators[source] = try ChunkAccumulator(source: source, directory: directory)
            }
            running = true
        }
        onStatus?("等待第一段语音…")
    }

    func append(_ packet: CapturedAudioBuffer) {
        queue.async { [weak self] in
            guard let self, self.running, let accumulator = self.accumulators[packet.source] else { return }
            do {
                try accumulator.writer.append(packet.buffer)
                if accumulator.writer.duration >= self.chunkDuration {
                    try self.flush(accumulator)
                }
            } catch {
                self.onError?(error)
            }
        }
    }

    func finish() async -> [TranscriptSegment] {
        queue.sync {
            running = false
            for accumulator in accumulators.values where accumulator.writer.duration > 0.25 {
                try? flush(accumulator)
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

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ASR", directoryHint: .isDirectory)
    }
}

private final class ChunkAccumulator: @unchecked Sendable {
    let source: TranscriptSource
    var writer: WAVChunkWriter
    var nextStartTime: TimeInterval = 0

    init(source: TranscriptSource, directory: URL) throws {
        self.source = source
        writer = try WAVChunkWriter(directory: directory)
    }
}
