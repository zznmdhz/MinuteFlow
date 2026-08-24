import Foundation

/// Collects the small amount of timing metadata needed to place independently
/// written source files on one active-meeting timeline. Audio remains in the
/// original files; this object only records where each contiguous run belongs.
final class RecordingTimelineBuilder: @unchecked Sendable {
    private struct ActivePeriod {
        let id: UUID
        let logicalStartFrame: Int64
        var monotonicOrigin: TimeInterval?
    }

    private struct OpenRun {
        let periodID: UUID
        let sourceStartFrame: Int64
        var frameCount: Int64
        var logicalStartFrame: Int64
        var lastCaptureEnd: TimeInterval
        let timestampQuality: AudioCaptureTimestampQuality
    }

    private struct CompletedRun {
        let periodID: UUID
        var epoch: AudioTimelineEpoch
    }

    private let lock = NSLock()
    private let sampleRate: Double
    private var activePeriod: ActivePeriod?
    private var openRuns: [TranscriptSource: OpenRun] = [:]
    private var completedEpochs: [TranscriptSource: [CompletedRun]] = [:]

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
    }

    func reset() {
        lock.withLock {
            activePeriod = nil
            openRuns = [:]
            completedEpochs = [:]
        }
    }

    /// Starts a new active recording period. Wall-clock time spent while paused
    /// is deliberately excluded by supplying the accumulated active duration.
    func beginActivePeriod(logicalStart: TimeInterval) {
        lock.withLock {
            closeAllRuns()
            activePeriod = ActivePeriod(
                id: UUID(),
                logicalStartFrame: frames(for: logicalStart),
                monotonicOrigin: nil
            )
        }
    }

    @discardableResult
    func endActivePeriod() -> TimeInterval {
        lock.withLock {
            closeAllRuns()
            activePeriod = nil
            return logicalEndTime()
        }
    }

    func record(_ packet: CapturedAudioBuffer) {
        guard let timing = packet.timing,
              timing.outputSampleRate > 0,
              timing.outputFrameCount > 0 else { return }

        lock.withLock {
            guard var period = activePeriod else { return }

            let now = ProcessInfo.processInfo.systemUptime
            let sharesHostClock = abs(timing.monotonicTime - now) <= 5
            let hasTrustworthyTimestamp = sharesHostClock && timing.monotonicTime.isFinite
            let comparableTime = hasTrustworthyTimestamp ? timing.monotonicTime : now
            if period.monotonicOrigin == nil {
                period.monotonicOrigin = comparableTime
                activePeriod = period
            } else if let currentOrigin = period.monotonicOrigin, comparableTime < currentOrigin {
                let shift = frames(for: currentOrigin - comparableTime)
                period.monotonicOrigin = comparableTime
                activePeriod = period
                for source in Array(openRuns.keys) where openRuns[source]?.periodID == period.id {
                    openRuns[source]?.logicalStartFrame += shift
                }
                for source in Array(completedEpochs.keys) {
                    guard var runs = completedEpochs[source] else { continue }
                    for index in runs.indices where runs[index].periodID == period.id {
                        let epoch = runs[index].epoch
                        runs[index].epoch = AudioTimelineEpoch(
                            sourceStartFrame: epoch.sourceStartFrame,
                            frameCount: epoch.frameCount,
                            logicalStartFrame: epoch.logicalStartFrame + shift,
                            timestampQuality: epoch.timestampQuality
                        )
                    }
                    completedEpochs[source] = runs
                }
            }
            let captureDelta = comparableTime - (period.monotonicOrigin ?? comparableTime)
            let validCaptureDelta = captureDelta.isFinite && captureDelta >= -0.25
            let normalizedCaptureDelta = validCaptureDelta ? max(0, captureDelta) : 0
            let logicalStart = period.logicalStartFrame + frames(for: normalizedCaptureDelta)
            let captureEnd = timing.monotonicTime + timing.duration

            if var run = openRuns[packet.source] {
                let sourceFramesAreContiguous = run.sourceStartFrame + run.frameCount == timing.outputStartFrame
                let captureGap = timing.monotonicTime - run.lastCaptureEnd
                let captureIsContiguous = captureGap.isFinite && captureGap >= -0.1 && captureGap <= 0.12
                if run.periodID == period.id, sourceFramesAreContiguous, captureIsContiguous {
                    run.frameCount += timing.outputFrameCount
                    run.lastCaptureEnd = captureEnd
                    openRuns[packet.source] = run
                    return
                }
                closeRun(for: packet.source)
            }

            openRuns[packet.source] = OpenRun(
                periodID: period.id,
                sourceStartFrame: timing.outputStartFrame,
                frameCount: timing.outputFrameCount,
                logicalStartFrame: logicalStart,
                lastCaptureEnd: captureEnd,
                timestampQuality: hasTrustworthyTimestamp && validCaptureDelta
                    ? timing.timestampQuality
                    : .callbackClock
            )
        }
    }

    func manifest(
        logicalDuration: TimeInterval,
        relativePaths: [TranscriptSource: String],
        channelCounts: [TranscriptSource: Int]
    ) -> AudioMixTimelineManifest {
        lock.withLock {
            closeAllRuns()
            let tracks = relativePaths.compactMap { source, path -> AudioMixTrackManifest? in
                guard let runs = completedEpochs[source], !runs.isEmpty else { return nil }
                return AudioMixTrackManifest(
                    source: source,
                    relativePath: path,
                    channelCount: channelCounts[source] ?? 1,
                    epochs: runs.map(\.epoch).sorted { $0.logicalStartFrame < $1.logicalStartFrame }
                )
            }
            return AudioMixTimelineManifest(
                timelineSampleRate: sampleRate,
                logicalDurationFrames: frames(for: logicalDuration),
                tracks: tracks
            )
        }
    }

    private func closeAllRuns() {
        for source in Array(openRuns.keys) {
            closeRun(for: source)
        }
    }

    private func closeRun(for source: TranscriptSource) {
        guard let run = openRuns.removeValue(forKey: source), run.frameCount > 0 else { return }
        completedEpochs[source, default: []].append(CompletedRun(
            periodID: run.periodID,
            epoch: AudioTimelineEpoch(
                sourceStartFrame: run.sourceStartFrame,
                frameCount: run.frameCount,
                logicalStartFrame: run.logicalStartFrame,
                timestampQuality: run.timestampQuality
            )
        ))
    }

    private func frames(for duration: TimeInterval) -> Int64 {
        Int64((max(0, duration) * sampleRate).rounded())
    }

    private func logicalEndTime() -> TimeInterval {
        let completedEnd = completedEpochs.values
            .flatMap { $0 }
            .map { $0.epoch.logicalStartFrame + $0.epoch.frameCount }
            .max() ?? 0
        let openEnd = openRuns.values
            .map { $0.logicalStartFrame + $0.frameCount }
            .max() ?? 0
        return Double(max(completedEnd, openEnd)) / sampleRate
    }
}
