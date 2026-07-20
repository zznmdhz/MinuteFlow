@preconcurrency import AVFoundation
import Foundation

final class RemoteRealtimeTranscriptionService: @unchecked Sendable {
    var onSegment: (@Sendable (TranscriptSegment) -> Void)?
    /// A replaceable, non-final result. It is never added to `finish()` output
    /// or persisted by this service. The final segment uses the same ID.
    var onPreview: (@Sendable (TranscriptSegment) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onError: (@Sendable (Error) -> Void)?

    private let queue = DispatchQueue(label: "com.minuteflow.remote-asr", qos: .userInitiated)
    private let client: any ASRClient
    private let resultsLock = NSLock()
    private var maximumChunkDuration: TimeInterval = 15
    private let minimumChunkDuration: TimeInterval = 0.8
    private let silenceToFlush: TimeInterval = 0.7
    private let silentWriterRotation: TimeInterval = 3
    private let previewDelay: TimeInterval = 3
    private let continuationOverlap: TimeInterval = 0.45
    private var configuration: ASRConfiguration?
    private var accumulators: [TranscriptSource: ChunkAccumulator] = [:]
    private var running = false
    private var completedSegments: [TranscriptSegment] = []
    private var recognitionGroups: [UUID: RecognitionGroupState] = [:]
    private var pendingUploads: [UploadJob] = []
    private var activeUploads: [UUID: Task<Void, Never>] = [:]
    private var activeUploadKinds: [UUID: UploadKind] = [:]
    // At most one preview per source is produced, so a third slot always leaves
    // capacity for a final result from either source.
    private let maximumConcurrentUploads = 3
    private let maximumPendingUploads = 8
    private let finishTimeout: Duration
    private let pendingDirectory: URL
    private var currentGeneration: UUID?
    private var finalizedGroupIDs: Set<UUID> = []

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
            self.maximumChunkDuration = min(max(maximumChunkDuration, 10), 30)
            accumulators = [:]
            resultsLock.withLock { completedSegments = [] }
            recognitionGroups = [:]
            finalizedGroupIDs = []
            pendingUploads = []
            currentGeneration = UUID()
            for source in sources {
                accumulators[source] = try ChunkAccumulator(sessionID: sessionID, source: source, directory: directory)
            }
            running = true
        }
        onStatus?("智能分段已启动 · 停顿后定稿")
    }

    func append(_ packet: CapturedAudioBuffer) {
        queue.async { [weak self] in
            guard let self, self.running, let accumulator = self.accumulators[packet.source] else { return }
            do {
                try accumulator.append(packet.buffer)
                let inputDuration = packet.buffer.format.sampleRate > 0
                    ? Double(packet.buffer.frameLength) / packet.buffer.format.sampleRate
                    : 0
                let level = AudioLevelMeter.normalizedLevel(for: packet.buffer)
                accumulator.observe(level: level, duration: inputDuration)

                let shouldFlushForSilence = accumulator.hasSpeech
                    && accumulator.activeDuration >= self.minimumChunkDuration
                    && accumulator.trailingSilence >= self.silenceToFlush
                let reachedMaximum = accumulator.hasSpeech
                    && accumulator.activeDuration >= self.maximumChunkDuration

                if accumulator.hasSpeech,
                   accumulator.activeDuration >= self.previewDelay,
                   !accumulator.previewSubmitted {
                    try self.submitPreview(accumulator)
                }

                if shouldFlushForSilence {
                    try self.flush(accumulator, boundaryReason: .naturalPause, isTerminal: true)
                } else if reachedMaximum {
                    try self.flush(accumulator, boundaryReason: .forcedHardLimit, isTerminal: false)
                } else if !accumulator.hasSpeech && accumulator.writer.duration >= self.silentWriterRotation {
                    try self.discardSilentChunk(accumulator)
                }
            } catch {
                self.onError?(error)
            }
        }
    }

    /// Ends the current utterance without stopping the transcription session.
    /// Used for explicit pause/resume boundaries and a single-source failure so
    /// text from opposite sides of that boundary is never merged silently.
    func splitCurrentUtterances(
        reason: TranscriptBoundaryReason,
        sources: Set<TranscriptSource>? = nil
    ) {
        queue.sync {
            guard running else { return }
            for (source, accumulator) in accumulators where sources?.contains(source) ?? true {
                if accumulator.hasSpeech, accumulator.activeDuration > 0.25 {
                    try? flush(accumulator, boundaryReason: reason, isTerminal: true)
                } else if accumulator.writer.duration > 0 {
                    try? discardSilentChunk(accumulator)
                }
            }
        }
    }

    func finish() async -> [TranscriptSegment] {
        queue.sync {
            running = false
            cancelOutstandingPreviews()
            for accumulator in accumulators.values {
                if accumulator.hasSpeech, accumulator.activeDuration > 0.25 {
                    try? flush(accumulator, boundaryReason: .recordingStopped, isTerminal: true)
                } else {
                    accumulator.writer.close()
                    try? FileManager.default.removeItem(at: accumulator.writer.url)
                }
                accumulator.removeUnusedWriters()
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

    private func submitPreview(_ accumulator: ChunkAccumulator) throws {
        guard let configuration, let previewWriter = accumulator.takePreviewWriter() else { return }
        let duration = previewWriter.duration
        previewWriter.close()
        guard duration > 0.25 else {
            try? FileManager.default.removeItem(at: previewWriter.url)
            return
        }
        let job = UploadJob(
            id: UUID(),
            sessionID: accumulator.sessionID,
            generation: currentGeneration ?? UUID(),
            url: previewWriter.url,
            duration: duration,
            startTime: accumulator.writerStartTime,
            source: accumulator.source,
            configuration: configuration,
            utteranceGroupID: accumulator.utteranceGroupID,
            sequence: -1,
            boundaryReason: .legacyUnknown,
            overlapBefore: 0,
            isTerminal: false,
            kind: .preview
        )
        guard pendingUploads.count < maximumPendingUploads else {
            try? FileManager.default.removeItem(at: job.url)
            return
        }
        pendingUploads.append(job)
        pumpUploads()
        onStatus?("正在生成临时预览…")
    }

    private func flush(
        _ accumulator: ChunkAccumulator,
        boundaryReason: TranscriptBoundaryReason,
        isTerminal: Bool
    ) throws {
        guard let configuration else { return }
        let oldWriter = accumulator.writer
        let duration = oldWriter.duration
        let startTime = accumulator.writerStartTime
        let groupID = accumulator.utteranceGroupID
        let sequence = accumulator.sequence
        let jobOverlapBefore = accumulator.overlapBefore
        oldWriter.close()
        accumulator.discardPreviewWriter()
        let endTime = startTime + duration

        let nextWriter = try WAVChunkWriter(directory: Self.temporaryDirectory())
        let nextPreviewWriter = isTerminal ? try WAVChunkWriter(directory: Self.temporaryDirectory()) : nil
        var overlapBefore: TimeInterval = 0
        if !isTerminal,
           let overlapBuffer = try WAVChunkWriter.readTail(from: oldWriter.url, duration: continuationOverlap) {
            try nextWriter.append(overlapBuffer)
            overlapBefore = nextWriter.duration
        }
        accumulator.advance(
            to: nextWriter,
            nextStartTime: endTime - overlapBefore,
            continuingGroup: !isTerminal,
            overlapDuration: overlapBefore,
            nextPreviewWriter: nextPreviewWriter
        )

        onStatus?("正在识别 \(Int(startTime))–\(Int(startTime + duration)) 秒…")
        let job = UploadJob(
            id: UUID(),
            sessionID: accumulator.sessionID,
            generation: currentGeneration ?? UUID(),
            url: oldWriter.url,
            duration: duration,
            startTime: startTime,
            source: accumulator.source,
            configuration: configuration,
            utteranceGroupID: groupID,
            sequence: sequence,
            boundaryReason: boundaryReason,
            overlapBefore: jobOverlapBefore,
            isTerminal: isTerminal,
            kind: .final
        )
        var group = recognitionGroups[groupID] ?? RecognitionGroupState(source: accumulator.source)
        group.enqueuedSequences.insert(sequence)
        if isTerminal { group.terminalSequence = sequence }
        recognitionGroups[groupID] = group
        guard pendingUploads.count < maximumPendingUploads else {
            preserveFailedChunk(job, reason: "等待队列达到上限")
            markJobComplete(job, result: .failure(ASRQueueError.backlogLimitReached))
            onError?(ASRQueueError.backlogLimitReached)
            return
        }
        if let firstPreview = pendingUploads.firstIndex(where: { $0.kind == .preview }) {
            pendingUploads.insert(job, at: firstPreview)
        } else {
            pendingUploads.append(job)
        }
        pumpUploads()
    }

    private func discardSilentChunk(_ accumulator: ChunkAccumulator) throws {
        let duration = accumulator.writer.duration
        let oldURL = accumulator.writer.url
        accumulator.writer.close()
        try? FileManager.default.removeItem(at: oldURL)
        let nextWriter = try WAVChunkWriter(directory: Self.temporaryDirectory())
        let nextPreviewWriter = try WAVChunkWriter(directory: Self.temporaryDirectory())
        accumulator.discardAndAdvance(to: nextWriter, previewWriter: nextPreviewWriter, duration: duration)
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
            activeUploadKinds[job.id] = job.kind
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
        activeUploadKinds[job.id] = nil
        guard job.generation == currentGeneration else {
            if job.kind == .preview {
                try? FileManager.default.removeItem(at: job.url)
            } else {
                preserveFailedChunk(job, reason: "转写任务已取消或属于上一条会议")
            }
            return
        }
        if job.kind == .preview {
            completePreview(job, result: result)
            pumpUploads()
            return
        }
        switch result {
        case .success(let text):
            try? FileManager.default.removeItem(at: job.url)
            markJobComplete(job, result: .success(text))
            onStatus?("已识别至 \(Int(job.startTime + job.duration)) 秒，等待下一段…")
        case .failure(let error):
            preserveFailedChunk(job, reason: error.localizedDescription)
            markJobComplete(job, result: .failure(error))
            onError?(error)
        }

        pumpUploads()
    }

    private func completePreview(_ job: UploadJob, result: Result<String, Error>) {
        try? FileManager.default.removeItem(at: job.url)
        guard !finalizedGroupIDs.contains(job.utteranceGroupID) else { return }
        guard case .success(let text) = result else {
            onStatus?("临时预览暂不可用；最终转写仍在继续")
            return
        }
        let preview = TranscriptSegment(
            id: job.utteranceGroupID,
            startTime: job.startTime,
            endTime: job.startTime + job.duration,
            text: text,
            source: job.source,
            isFinal: false,
            originalText: text
        )
        onPreview?(preview)
        onStatus?("临时预览已显示，等待停顿后定稿…")
    }

    private func markJobComplete(_ job: UploadJob, result: Result<String, Error>) {
        guard var group = recognitionGroups[job.utteranceGroupID] else { return }
        switch result {
        case .success(let rawText):
            group.results[job.sequence] = RecognitionResult(
                id: job.id,
                startTime: job.startTime,
                endTime: job.startTime + job.duration,
                rawText: rawText,
                boundaryReason: job.boundaryReason,
                overlapBefore: job.overlapBefore
            )
        case .failure:
            group.failedSequences.insert(job.sequence)
        }
        recognitionGroups[job.utteranceGroupID] = group
        finalizeGroupIfReady(job.utteranceGroupID)
    }

    private func finalizeGroupIfReady(_ groupID: UUID) {
        guard let group = recognitionGroups[groupID], let terminal = group.terminalSequence else { return }
        let expected = Set(0...terminal)
        let completed = Set(group.results.keys).union(group.failedSequences)
        guard expected.isSubset(of: completed) else { return }
        recognitionGroups[groupID] = nil
        finalizedGroupIDs.insert(groupID)

        let units = group.results.values.sorted {
            if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
            return $0.startTime < $1.startTime
        }
        guard !units.isEmpty else { return }
        let assembledText = TranscriptTextAssembler.assemble(units)
        let rawText = units.map(\.rawText).joined(separator: "\n")
        let fragments = units.map {
            TranscriptRecognitionFragment(
                id: $0.id,
                startTime: $0.startTime,
                endTime: $0.endTime,
                originalText: $0.rawText,
                boundaryReason: $0.boundaryReason,
                overlapBefore: $0.overlapBefore
            )
        }
        let segment = TranscriptSegment(
            id: groupID,
            startTime: units.map(\.startTime).min() ?? 0,
            endTime: units.map(\.endTime).max() ?? 0,
            text: assembledText,
            source: group.source,
            isFinal: true,
            originalText: rawText,
            recognitionFragments: fragments,
            boundaryReason: units.last?.boundaryReason
        )
        resultsLock.withLock {
            completedSegments.append(segment)
            completedSegments.sort {
                if $0.startTime == $1.startTime { return $0.id.uuidString < $1.id.uuidString }
                return $0.startTime < $1.startTime
            }
        }
        onSegment?(segment)
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

    private func cancelOutstandingPreviews() {
        let previews = pendingUploads.filter { $0.kind == .preview }
        pendingUploads.removeAll { $0.kind == .preview }
        previews.forEach { try? FileManager.default.removeItem(at: $0.url) }
        for (id, kind) in activeUploadKinds where kind == .preview {
            activeUploads[id]?.cancel()
        }
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
    let utteranceGroupID: UUID
    let sequence: Int
    let boundaryReason: TranscriptBoundaryReason
    let overlapBefore: TimeInterval
    let isTerminal: Bool
    let kind: UploadKind
}

private enum UploadKind: Sendable {
    case preview
    case final
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
    var previewWriter: WAVChunkWriter?
    var writerStartTime: TimeInterval = 0
    var hasSpeech = false
    var trailingSilence: TimeInterval = 0
    var candidateSpeechDuration: TimeInterval = 0
    var speechStartedAtWriterDuration: TimeInterval?
    var noiseFloor: Float = 0
    var utteranceGroupID = UUID()
    var sequence = 0
    var overlapBefore: TimeInterval = 0
    var previewSubmitted = false

    var activeDuration: TimeInterval {
        guard let speechStartedAtWriterDuration else { return 0 }
        return max(0, writer.duration - speechStartedAtWriterDuration)
    }

    init(sessionID: UUID, source: TranscriptSource, directory: URL) throws {
        self.sessionID = sessionID
        self.source = source
        writer = try WAVChunkWriter(directory: directory)
        previewWriter = try WAVChunkWriter(directory: directory)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        try writer.append(buffer)
        try previewWriter?.append(buffer)
    }

    func takePreviewWriter() -> WAVChunkWriter? {
        defer {
            previewWriter = nil
            previewSubmitted = true
        }
        return previewWriter
    }

    func discardPreviewWriter() {
        previewWriter?.close()
        if let previewURL = previewWriter?.url {
            try? FileManager.default.removeItem(at: previewURL)
        }
        previewWriter = nil
    }

    func observe(level: Float, duration: TimeInterval) {
        let speechThreshold = min(max(noiseFloor + 0.2, 0.1), 0.5)
        if level >= speechThreshold {
            candidateSpeechDuration += duration
            trailingSilence = 0
            if !hasSpeech, candidateSpeechDuration >= 0.12 {
                hasSpeech = true
                speechStartedAtWriterDuration = max(0, writer.duration - candidateSpeechDuration)
            }
        } else {
            if hasSpeech {
                trailingSilence += duration
            } else {
                candidateSpeechDuration = 0
                // Slowly follow each source's ambient level. The upper bound
                // prevents a loud transient from redefining speech as noise.
                noiseFloor = min(0.3, noiseFloor * 0.98 + level * 0.02)
            }
        }
    }

    func advance(
        to nextWriter: WAVChunkWriter,
        nextStartTime: TimeInterval,
        continuingGroup: Bool,
        overlapDuration: TimeInterval,
        nextPreviewWriter: WAVChunkWriter?
    ) {
        writer = nextWriter
        previewWriter = nextPreviewWriter
        writerStartTime = nextStartTime
        overlapBefore = overlapDuration
        trailingSilence = 0
        candidateSpeechDuration = 0
        speechStartedAtWriterDuration = continuingGroup ? 0 : nil
        hasSpeech = continuingGroup
        if continuingGroup {
            sequence += 1
        } else {
            utteranceGroupID = UUID()
            sequence = 0
            previewSubmitted = false
        }
    }

    func discardAndAdvance(
        to nextWriter: WAVChunkWriter,
        previewWriter nextPreviewWriter: WAVChunkWriter,
        duration: TimeInterval
    ) {
        discardPreviewWriter()
        writer = nextWriter
        previewWriter = nextPreviewWriter
        writerStartTime += duration
        hasSpeech = false
        trailingSilence = 0
        candidateSpeechDuration = 0
        speechStartedAtWriterDuration = nil
        overlapBefore = 0
        previewSubmitted = false
    }

    func removeUnusedWriters() {
        writer.close()
        try? FileManager.default.removeItem(at: writer.url)
        discardPreviewWriter()
    }
}

private struct RecognitionResult: Sendable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let rawText: String
    let boundaryReason: TranscriptBoundaryReason
    let overlapBefore: TimeInterval
}

private struct RecognitionGroupState: Sendable {
    let source: TranscriptSource
    var enqueuedSequences: Set<Int> = []
    var terminalSequence: Int?
    var results: [Int: RecognitionResult] = [:]
    var failedSequences: Set<Int> = []
}

private enum TranscriptTextAssembler {
    static func assemble(_ units: [RecognitionResult]) -> String {
        units.reduce(into: "") { assembled, unit in
            let next = unit.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !next.isEmpty else { return }
            guard !assembled.isEmpty else {
                assembled = next
                return
            }
            if unit.overlapBefore > 0 {
                assembled = stitch(assembled, next)
            } else {
                assembled += separator(between: assembled, and: next) + next
            }
        }
    }

    private static func stitch(_ previous: String, _ next: String) -> String {
        let left = Array(previous)
        let right = Array(next)
        let maximum = min(40, left.count, right.count)
        if maximum >= 2 {
            for count in stride(from: maximum, through: 2, by: -1) {
                let suffix = String(left.suffix(count)).lowercased()
                let prefix = String(right.prefix(count)).lowercased()
                guard suffix == prefix else { continue }
                let remainder = String(right.dropFirst(count))
                return previous + separator(between: previous, and: remainder) + remainder
            }
        }
        return previous + separator(between: previous, and: next) + next
    }

    private static func separator(between previous: String, and next: String) -> String {
        guard let left = previous.last, let right = next.first else { return "" }
        return isASCIIWordCharacter(left) && isASCIIWordCharacter(right) ? " " : ""
    }

    private static func isASCIIWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }
}
