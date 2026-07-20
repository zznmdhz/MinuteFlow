import Foundation

final class RemoteRealtimeTranscriptionService: @unchecked Sendable {
    var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.minuteflow.remote-asr", qos: .userInitiated)
    private let client: any ASRClient
    private let resultsLock = NSLock()
    private var maximumChunkDuration: TimeInterval = 3
    private let minimumChunkDuration: TimeInterval = 0.8
    private let silenceToFlush: TimeInterval = 0.7
    private let speechLevelThreshold: Float = 0.1
    private var configuration: ASRConfiguration?
    private var accumulators: [TranscriptSource: ChunkAccumulator] = [:]
    private var running = false
    private var completedSegments: [TranscriptSegment] = []
    private var pendingUploads: [UploadJob] = []
    private var activeUploads: [UUID: Task<Void, Never>] = [:]
    private let maximumConcurrentUploads = 2
    private let maximumPendingUploads = 8
    private let finishTimeout: Duration
    private let pendingDirectory: URL
    private var currentGeneration: UUID?

    init(
        client: any ASRClient = RemoteASRClient(),
        finishTimeout: Duration = .seconds(15),
        pendingDirectory: URL? = nil
    ) {
        self.client = client
        self.finishTimeout = finishTimeout
        self.pendingDirectory = pendingDirectory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appending(path: "MinuteFlow/PendingTranscriptions", directoryHint: .isDirectory)
    }

    func start(
        sessionID: UUID,
        sources: Set<TranscriptSource>,
        configuration: ASRConfiguration,
        maximumChunkDuration: TimeInterval
    ) throws {
        let directory = Self.temporaryDirectory()
        try queue.sync {
            guard activeUploads.isEmpty, pendingUploads.isEmpty else {
                throw ASRQueueError.previousCleanupPending
            }
            self.configuration = configuration
            self.maximumChunkDuration = min(max(maximumChunkDuration, 2), 8)
            accumulators = [:]
            resultsLock.withLock { completedSegments = [] }
            pendingUploads = []
            currentGeneration = UUID()
            for source in sources {
                accumulators[source] = try ChunkAccumulator(sessionID: sessionID, source: source, directory: directory)
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

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: finishTimeout)
        while queue.sync(execute: { !pendingUploads.isEmpty || !activeUploads.isEmpty }) {
            if clock.now >= deadline {
                queue.sync { cancelOutstandingUploads(reason: "停止录音时达到 15 秒收尾上限") }
                onStatus?("录音已保存；未完成的转写片段已留在本机待处理目录")
                return resultsLock.withLock { completedSegments.sorted { $0.startTime < $1.startTime } }
            }
            try? await Task.sleep(for: .milliseconds(100))
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

        onStatus?("正在识别 \(Int(startTime))–\(Int(startTime + duration)) 秒…")
        let job = UploadJob(
            id: UUID(),
            sessionID: accumulator.sessionID,
            generation: currentGeneration ?? UUID(),
            url: oldWriter.url,
            duration: duration,
            startTime: startTime,
            source: accumulator.source,
            configuration: configuration
        )
        guard pendingUploads.count < maximumPendingUploads else {
            preserveFailedChunk(job, reason: "等待队列达到上限")
            onError?(ASRQueueError.backlogLimitReached)
            return
        }
        pendingUploads.append(job)
        pumpUploads()
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

    private func pumpUploads() {
        while activeUploads.count < maximumConcurrentUploads, !pendingUploads.isEmpty {
            let job = pendingUploads.removeFirst()
            let task = Task { [weak self] in
                guard let self else { return }
                let result: Result<String, Error>
                do {
                    result = .success(try await self.transcribeWithRetry(job))
                } catch {
                    result = .failure(error)
                }
                self.queue.async { [weak self] in
                    self?.completeUpload(job, result: result)
                }
            }
            activeUploads[job.id] = task
        }
        let backlog = pendingUploads.count + activeUploads.count
        if backlog > maximumConcurrentUploads {
            onStatus?("网络较慢，已有 \(backlog) 段排队；录音不会中断")
        }
    }

    private func transcribeWithRetry(_ job: UploadJob) async throws -> String {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                return try await client.transcribe(wavURL: job.url, configuration: job.configuration)
            } catch {
                lastError = error
                guard attempt < 2, Self.isRetryable(error) else { throw error }
                let delay = UInt64(500 * (1 << attempt)) * 1_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
        throw lastError ?? RemoteModelError.invalidResponse
    }

    private func completeUpload(_ job: UploadJob, result: Result<String, Error>) {
        activeUploads[job.id] = nil
        guard job.generation == currentGeneration else {
            preserveFailedChunk(job, reason: "转写任务已取消或属于上一条会议")
            return
        }
        switch result {
        case .success(let text):
            try? FileManager.default.removeItem(at: job.url)
            let segment = TranscriptSegment(
                startTime: job.startTime,
                endTime: job.startTime + job.duration,
                text: text,
                source: job.source,
                isFinal: true
            )
            resultsLock.withLock { completedSegments.append(segment) }
            onSegment?(segment)
            onStatus?("已识别至 \(Int(job.startTime + job.duration)) 秒，等待下一段…")
        case .failure(let error):
            preserveFailedChunk(job, reason: error.localizedDescription)
            onError?(error)
        }

        pumpUploads()
    }

    private func preserveFailedChunk(_ job: UploadJob, reason: String) {
        let directory = pendingDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: job.url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: job.url.path) {
                try FileManager.default.moveItem(at: job.url, to: destination)
            }
            let manifest = PendingTranscriptionManifest(
                version: 1,
                sessionID: job.sessionID,
                source: job.source.rawValue,
                startTime: job.startTime,
                duration: job.duration,
                endpoint: job.configuration.endpoint.absoluteString,
                model: job.configuration.model,
                language: job.configuration.language,
                transport: job.configuration.transport.rawValue,
                reason: String(reason.prefix(300)),
                createdAt: Date()
            )
            let manifestURL = destination.deletingPathExtension().appendingPathExtension("json")
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            onStatus?("有片段暂未识别，已连同处理清单保存在本机")
        } catch {
            onError?(error)
        }
    }

    private func cancelOutstandingUploads(reason: String) {
        let queued = pendingUploads
        pendingUploads.removeAll()
        queued.forEach { preserveFailedChunk($0, reason: reason) }
        currentGeneration = nil
        activeUploads.values.forEach { $0.cancel() }
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

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-ASR", directoryHint: .isDirectory)
    }
}

private struct UploadJob: Sendable {
    let id: UUID
    let sessionID: UUID
    let generation: UUID
    let url: URL
    let duration: TimeInterval
    let startTime: TimeInterval
    let source: TranscriptSource
    let configuration: ASRConfiguration
}

private struct PendingTranscriptionManifest: Codable {
    let version: Int
    let sessionID: UUID
    let source: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let endpoint: String
    let model: String
    let language: String
    let transport: String
    let reason: String
    let createdAt: Date
}

private enum ASRQueueError: LocalizedError {
    case backlogLimitReached
    case previousCleanupPending

    var errorDescription: String? {
        switch self {
        case .backlogLimitReached:
            "网络识别队列已满；该语音片段和处理清单已保存在本机，原始会议录音不受影响。"
        case .previousCleanupPending:
            "上一条会议的网络转写仍在取消中；本次只录音，不启动远程转写。"
        }
    }
}

private final class ChunkAccumulator: @unchecked Sendable {
    let sessionID: UUID
    let source: TranscriptSource
    var writer: WAVChunkWriter
    var nextStartTime: TimeInterval = 0
    var hasSpeech = false
    var trailingSilence: TimeInterval = 0

    init(sessionID: UUID, source: TranscriptSource, directory: URL) throws {
        self.sessionID = sessionID
        self.source = source
        writer = try WAVChunkWriter(directory: directory)
    }
}
