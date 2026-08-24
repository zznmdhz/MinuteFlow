@preconcurrency import AVFoundation
import Foundation

protocol SpeakerDiarizing: Sendable {
    func analyze(audioURL: URL) async throws -> SpeakerDiarizationResult
}

/// A privacy-preserving acoustic diarizer. It clusters short voiced windows by
/// pitch and vocal-tract proxies extracted directly from PCM audio. It is less
/// accurate than a large neural diarization model, but requires no upload,
/// account, runtime download, or enrolled voiceprint.
struct LocalSpeakerDiarizer: SpeakerDiarizing, Sendable {
    func analyze(audioURL: URL) async throws -> SpeakerDiarizationResult {
        try await Task.detached(priority: .utility) {
            try Self.analyzeSynchronously(audioURL: audioURL)
        }.value
    }

    private static func analyzeSynchronously(audioURL: URL) throws -> SpeakerDiarizationResult {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioURL)
        } catch {
            throw SpeakerDiarizationError.unreadableAudio
        }
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeakerDiarizationError.unreadableAudio
        }

        let sampleRate = format.sampleRate
        let windowFrames = max(2_048, Int(sampleRate * 1.6))
        let hopFrames = max(1_024, Int(sampleRate * 0.8))
        let analysisRate = min(sampleRate, 4_000)
        let downsampleStride = max(1, Int(sampleRate / analysisRate))
        let readFrames: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: readFrames) else {
            throw SpeakerDiarizationError.unreadableAudio
        }

        var pending: [Float] = []
        pending.reserveCapacity(windowFrames + Int(readFrames))
        var pendingOffset = 0
        var windowStartFrame: Int64 = 0
        var windows: [AcousticWindow] = []

        while true {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: readFrames)
            } catch {
                // Some compressed AVAudioFile readers report an end-of-stream
                // decode error after returning all usable PCM frames.
                guard windows.isEmpty else { break }
                throw SpeakerDiarizationError.unreadableAudio
            }
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { break }
            let channelCount = Int(format.channelCount)
            for index in 0..<Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0..<channelCount { value += channels[channel][index] }
                pending.append(value / Float(channelCount))
            }

            while pending.count - pendingOffset >= windowFrames {
                var samples: [Float] = []
                samples.reserveCapacity(windowFrames / downsampleStride + 1)
                let end = pendingOffset + windowFrames
                for index in Swift.stride(from: pendingOffset, to: end, by: downsampleStride) {
                    samples.append(pending[index])
                }
                windows.append(featureWindow(
                    samples: samples,
                    sampleRate: analysisRate,
                    duration: Double(windowFrames) / sampleRate,
                    startTime: Double(windowStartFrame) / sampleRate
                ))
                pendingOffset += hopFrames
                windowStartFrame += Int64(hopFrames)
            }

            if pendingOffset > windowFrames * 2 {
                pending.removeFirst(pendingOffset)
                pendingOffset = 0
            }
        }

        guard windows.count >= 2 else { throw SpeakerDiarizationError.insufficientSpeech }
        let orderedLevels = windows.map(\.rmsDB).sorted()
        let lowIndex = min(orderedLevels.count - 1, Int(Double(orderedLevels.count - 1) * 0.18))
        let noiseDB = orderedLevels[lowIndex]
        let speechThresholdDB = min(-24, max(-50, noiseDB + 5))
        let voiced = windows.filter {
            $0.rmsDB >= speechThresholdDB && $0.pitchStrength >= 0.08
        }
        guard !voiced.isEmpty else { throw SpeakerDiarizationError.noSpeechDetected }
        guard voiced.count >= 3 else { throw SpeakerDiarizationError.insufficientSpeech }

        let normalized = normalize(voiced.map(\.features))
        let maximumClusters = min(4, max(1, voiced.count / 8))
        var best = ClusterCandidate.single(count: voiced.count, dimensions: normalized.first?.count ?? 0)
        if maximumClusters >= 2 {
            for clusterCount in 2...maximumClusters {
                let candidate = kMeans(normalized, clusterCount: clusterCount)
                let score = silhouetteScore(normalized, labels: candidate.labels, clusterCount: clusterCount)
                    - Float(clusterCount - 1) * 0.08
                guard candidate.clusterSizes.allSatisfy({ $0 >= 3 }) else { continue }
                if score > best.score, score >= 0.12 {
                    best = ClusterCandidate(
                        labels: candidate.labels,
                        centroids: candidate.centroids,
                        clusterSizes: candidate.clusterSizes,
                        score: score
                    )
                }
            }
        }

        var labels = smooth(best.labels)
        labels = stableSpeakerOrder(labels)
        let speakerCount = Set(labels).count
        let turns = buildTurns(
            voiced: voiced,
            normalizedFeatures: normalized,
            labels: labels,
            speakerCount: speakerCount
        )
        guard !turns.isEmpty else { throw SpeakerDiarizationError.noSpeechDetected }

        return SpeakerDiarizationResult(
            version: 1,
            generatedAt: Date(),
            sourceFileName: audioURL.lastPathComponent,
            method: "local-acoustic-v1",
            speakerCount: speakerCount,
            turns: turns
        )
    }

    private static func featureWindow(
        samples: [Float],
        sampleRate: Double,
        duration: TimeInterval,
        startTime: TimeInterval
    ) -> AcousticWindow {
        let analysisRate = sampleRate
        let count = max(1, samples.count)
        let energy = samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(count)
        let rms = sqrt(max(energy, 1e-12))
        let rmsDB = 20 * log10(max(rms, 1e-6))
        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        var zeroCrossings = 0
        if samples.count > 1 {
            for i in 1..<samples.count where (samples[i - 1] >= 0) != (samples[i] >= 0) {
                zeroCrossings += 1
            }
        }
        let zcr = Float(zeroCrossings) / Float(count)
        let crest = min(10, peak / max(rms, 1e-5)) / 10
        let firstDifference = differenceEnergy(samples, order: 1) / max(energy, 1e-10)
        let secondDifference = differenceEnergy(samples, order: 2) / max(energy, 1e-10)

        let centerCount = min(samples.count, max(512, Int(analysisRate * 0.16)))
        let centerStart = max(0, (samples.count - centerCount) / 2)
        let center = Array(samples[centerStart..<(centerStart + centerCount)])
        let centerEnergy = center.reduce(Float.zero) { $0 + $1 * $1 }
        let fixedLags = [1, 2, 4, 8, 16, 32, 64, 128]
        let correlations = fixedLags.map { lag in
            normalizedAutocorrelation(center, lag: lag, energy: centerEnergy)
        }

        let minimumLag = max(8, Int(analysisRate / 380))
        let maximumLag = min(center.count / 2, Int(analysisRate / 65))
        var bestLag = minimumLag
        var bestCorrelation: Float = 0
        if minimumLag <= maximumLag {
            for lag in Swift.stride(from: minimumLag, through: maximumLag, by: 4) {
                let correlation = normalizedAutocorrelation(center, lag: lag, energy: centerEnergy)
                if correlation > bestCorrelation {
                    bestCorrelation = correlation
                    bestLag = lag
                }
            }
        }
        let pitch = bestCorrelation >= 0.08 ? Float(analysisRate / Double(bestLag)) : 0
        let logPitch = pitch > 0 ? log(max(pitch, 1)) / log(400) : 0
        let features = [zcr, crest, firstDifference, secondDifference]
            + correlations
            + [logPitch, bestCorrelation]
        return AcousticWindow(
            startTime: startTime,
            endTime: startTime + duration,
            rmsDB: rmsDB,
            pitchStrength: bestCorrelation,
            features: features
        )
    }

    private static func differenceEnergy(_ samples: [Float], order: Int) -> Float {
        guard samples.count > order else { return 0 }
        var total: Float = 0
        if order == 1 {
            for index in 1..<samples.count {
                let difference = samples[index] - samples[index - 1]
                total += difference * difference
            }
            return total / Float(samples.count - 1)
        }
        for index in 2..<samples.count {
            let difference = samples[index] - 2 * samples[index - 1] + samples[index - 2]
            total += difference * difference
        }
        return total / Float(samples.count - 2)
    }

    private static func normalizedAutocorrelation(_ samples: [Float], lag: Int, energy: Float) -> Float {
        guard lag > 0, samples.count > lag, energy > 1e-10 else { return 0 }
        var value: Float = 0
        var delayedEnergy: Float = 0
        for index in lag..<samples.count {
            value += samples[index] * samples[index - lag]
            delayedEnergy += samples[index - lag] * samples[index - lag]
        }
        let currentEnergy = samples[lag...].reduce(Float.zero) { $0 + $1 * $1 }
        return min(1, max(-1, value / sqrt(max(currentEnergy * delayedEnergy, 1e-10))))
    }

    private static func normalize(_ vectors: [[Float]]) -> [[Float]] {
        guard let dimension = vectors.first?.count, dimension > 0 else { return vectors }
        var means = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for index in 0..<dimension { means[index] += vector[index] }
        }
        means = means.map { $0 / Float(vectors.count) }
        var deviations = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for index in 0..<dimension {
                let delta = vector[index] - means[index]
                deviations[index] += delta * delta
            }
        }
        deviations = deviations.map { sqrt($0 / Float(vectors.count)) }
        return vectors.map { vector in
            (0..<dimension).map { index in
                let value = (vector[index] - means[index]) / max(deviations[index], 1e-4)
                return min(3, max(-3, value))
            }
        }
    }

    private static func kMeans(_ points: [[Float]], clusterCount: Int) -> ClusterCandidate {
        var centroids: [[Float]] = [points[0]]
        while centroids.count < clusterCount {
            let next = points.max { left, right in
                nearestDistance(left, centroids: centroids) < nearestDistance(right, centroids: centroids)
            } ?? points[centroids.count % points.count]
            centroids.append(next)
        }
        var labels = [Int](repeating: 0, count: points.count)
        for _ in 0..<30 {
            let nextLabels = points.map { nearestCentroid($0, centroids: centroids) }
            if nextLabels == labels, !centroids.isEmpty { break }
            labels = nextLabels
            for cluster in 0..<clusterCount {
                let members = points.enumerated().filter { labels[$0.offset] == cluster }.map(\.element)
                guard !members.isEmpty else { continue }
                centroids[cluster] = meanVector(members)
            }
        }
        let sizes = (0..<clusterCount).map { cluster in labels.filter { $0 == cluster }.count }
        return ClusterCandidate(labels: labels, centroids: centroids, clusterSizes: sizes, score: -.greatestFiniteMagnitude)
    }

    private static func silhouetteScore(_ points: [[Float]], labels: [Int], clusterCount: Int) -> Float {
        guard clusterCount > 1 else { return 0 }
        let step = max(1, points.count / 400)
        var total: Float = 0
        var evaluated = 0
        for index in stride(from: 0, to: points.count, by: step) {
            let own = labels[index]
            var ownTotal: Float = 0
            var ownCount = 0
            var otherTotals = [Float](repeating: 0, count: clusterCount)
            var otherCounts = [Int](repeating: 0, count: clusterCount)
            for other in points.indices where other != index {
                let distance = squaredDistance(points[index], points[other])
                let label = labels[other]
                if label == own {
                    ownTotal += distance
                    ownCount += 1
                } else {
                    otherTotals[label] += distance
                    otherCounts[label] += 1
                }
            }
            let a = ownCount > 0 ? ownTotal / Float(ownCount) : 0
            let b = (0..<clusterCount)
                .filter { $0 != own && otherCounts[$0] > 0 }
                .map { otherTotals[$0] / Float(otherCounts[$0]) }
                .min() ?? a
            total += (b - a) / max(max(a, b), 1e-5)
            evaluated += 1
        }
        return evaluated > 0 ? total / Float(evaluated) : 0
    }

    private static func smooth(_ labels: [Int]) -> [Int] {
        guard labels.count >= 3 else { return labels }
        var result = labels
        for index in labels.indices {
            let lower = max(0, index - 2)
            let upper = min(labels.count - 1, index + 2)
            var counts: [Int: Int] = [:]
            for neighbor in lower...upper { counts[labels[neighbor], default: 0] += 1 }
            if let majority = counts.max(by: { $0.value < $1.value }), majority.value >= 3 {
                result[index] = majority.key
            }
        }
        if result.count >= 3 {
            for index in 1..<(result.count - 1) where result[index - 1] == result[index + 1] {
                result[index] = result[index - 1]
            }
        }
        return result
    }

    private static func stableSpeakerOrder(_ labels: [Int]) -> [Int] {
        var mapping: [Int: Int] = [:]
        var next = 0
        return labels.map { label in
            if let mapped = mapping[label] { return mapped }
            mapping[label] = next
            defer { next += 1 }
            return next
        }
    }

    private static func buildTurns(
        voiced: [AcousticWindow],
        normalizedFeatures: [[Float]],
        labels: [Int],
        speakerCount: Int
    ) -> [SpeakerTurn] {
        guard !voiced.isEmpty else { return [] }
        let centroids = (0..<speakerCount).map { speaker in
            meanVector(normalizedFeatures.enumerated().filter { labels[$0.offset] == speaker }.map(\.element))
        }
        var turns: [SpeakerTurn] = []
        for index in voiced.indices {
            let speaker = labels[index]
            let ownDistance = squaredDistance(normalizedFeatures[index], centroids[speaker])
            let otherDistance = centroids.enumerated()
                .filter { $0.offset != speaker }
                .map { squaredDistance(normalizedFeatures[index], $0.element) }
                .min() ?? ownDistance + 1
            let confidence = speakerCount == 1
                ? Float(0.65)
                : min(0.95, max(0.35, 1 - ownDistance / max(otherDistance, 1e-4)))
            let speakerID = "speaker-\(speaker + 1)"
            if var last = turns.last,
               last.speakerID == speakerID,
               voiced[index].startTime - last.endTime <= 1.0 {
                last.endTime = max(last.endTime, voiced[index].endTime)
                last.confidence = (last.confidence + confidence) / 2
                turns[turns.count - 1] = last
            } else {
                turns.append(SpeakerTurn(
                    startTime: voiced[index].startTime,
                    endTime: voiced[index].endTime,
                    speakerID: speakerID,
                    confidence: confidence
                ))
            }
        }
        for index in 1..<turns.count where turns[index].startTime < turns[index - 1].endTime {
            let boundary = (turns[index].startTime + turns[index - 1].endTime) / 2
            turns[index - 1].endTime = boundary
            turns[index].startTime = boundary
        }
        return turns.filter { $0.endTime - $0.startTime >= 0.3 }
    }

    private static func nearestCentroid(_ point: [Float], centroids: [[Float]]) -> Int {
        centroids.indices.min { squaredDistance(point, centroids[$0]) < squaredDistance(point, centroids[$1]) } ?? 0
    }

    private static func nearestDistance(_ point: [Float], centroids: [[Float]]) -> Float {
        centroids.map { squaredDistance(point, $0) }.min() ?? 0
    }

    private static func squaredDistance(_ left: [Float], _ right: [Float]) -> Float {
        zip(left, right).reduce(Float.zero) { result, pair in
            let delta = pair.0 - pair.1
            return result + delta * delta
        }
    }

    private static func meanVector(_ vectors: [[Float]]) -> [Float] {
        guard let dimension = vectors.first?.count, !vectors.isEmpty else { return [] }
        var result = [Float](repeating: 0, count: dimension)
        for vector in vectors {
            for index in 0..<dimension { result[index] += vector[index] }
        }
        return result.map { $0 / Float(vectors.count) }
    }
}

private struct AcousticWindow: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let rmsDB: Float
    let pitchStrength: Float
    let features: [Float]
}

private struct ClusterCandidate: Sendable {
    let labels: [Int]
    let centroids: [[Float]]
    let clusterSizes: [Int]
    let score: Float

    static func single(count: Int, dimensions: Int) -> ClusterCandidate {
        ClusterCandidate(
            labels: [Int](repeating: 0, count: count),
            centroids: [[Float](repeating: 0, count: dimensions)],
            clusterSizes: [count],
            score: 0
        )
    }
}
