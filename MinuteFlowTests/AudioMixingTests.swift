import AVFoundation
import Foundation
import XCTest
@testable import MinuteFlow

final class AudioMixingTests: XCTestCase {
    func testAudioFileWriterReportsContiguousNormalizedFramePositions() throws {
        let root = temporaryDirectory(named: "WriterReceipt")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputURL = root.appending(path: "track.m4a")
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: 4_410
        ))
        buffer.frameLength = 4_410
        let writer = try AudioFileWriter(url: outputURL, channelCount: 1)

        let first = try writer.write(buffer)
        let second = try writer.write(buffer)
        writer.close()

        XCTAssertEqual(first.startFrame, 0)
        XCTAssertGreaterThan(first.frameCount, 0)
        XCTAssertEqual(second.startFrame, first.frameCount)
        XCTAssertEqual(first.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(second.sampleRate, 48_000, accuracy: 0.5)
    }

    func testOldMeetingMetadataDecodesWithoutMixFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let session = MeetingSession(
            id: UUID(),
            title: "旧会议",
            sourceSelection: .both,
            startTime: now,
            duration: 12,
            recordingStatus: .completed,
            systemAudioURL: URL(fileURLWithPath: "/tmp/system.m4a"),
            microphoneAudioURL: URL(fileURLWithPath: "/tmp/microphone.m4a"),
            createdAt: now,
            updatedAt: now
        )
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any]
        )
        object.removeValue(forKey: "mixedAudioURL")
        object.removeValue(forKey: "mixState")
        object.removeValue(forKey: "mixMessage")
        object.removeValue(forKey: "mixUpdatedAt")

        let decoded = try JSONDecoder().decode(
            MeetingSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.title, "旧会议")
        XCTAssertNil(decoded.mixedAudioURL)
        XCTAssertNil(decoded.mixState)
        XCTAssertNil(decoded.mixMessage)
        XCTAssertNil(decoded.mixUpdatedAt)
    }

    func testRepositoryProvidesStableMixedAndManifestPaths() throws {
        let root = temporaryDirectory(named: "Repository")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LocalMeetingRepository(rootDirectory: root)
        let session = try repository.createSession(title: "混音路径", sourceSelection: .both)

        XCTAssertEqual(repository.mixedAudioURL(for: session.id).lastPathComponent, "mixed.m4a")
        XCTAssertEqual(
            repository.mixedAudioURL(for: session.id).deletingLastPathComponent().lastPathComponent,
            "audio"
        )
        XCTAssertEqual(repository.mixManifestURL(for: session.id).lastPathComponent, "mix-manifest.json")

        let manifest = AudioMixTimelineManifest(
            logicalDurationFrames: 4_800,
            tracks: [
                AudioMixTrackManifest(
                    source: .system,
                    relativePath: session.systemAudioURL?.lastPathComponent ?? "system.m4a",
                    channelCount: 2,
                    epochs: [AudioTimelineEpoch(
                        sourceStartFrame: 0,
                        frameCount: 4_800,
                        logicalStartFrame: 0
                    )]
                )
            ]
        )
        _ = try repository.saveMixManifest(manifest, sessionID: session.id)
        XCTAssertEqual(try repository.loadMixManifest(sessionID: session.id), manifest)
    }

    func testSingleReadableSourceProducesDegradedStereoM4AWithoutChangingRawFile() async throws {
        let root = temporaryDirectory(named: "Single")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rawURL = root.appending(path: "microphone.caf")
        let outputURL = root.appending(path: "mixed.m4a")
        try writeTone(url: rawURL, duration: 0.3, amplitude: 0.35, channels: 1)
        let originalData = try Data(contentsOf: rawURL)

        let result = try await AVFoundationOfflineAudioMixer().mix(AudioMixRequest(
            inputs: [AudioMixInput(source: .microphone, url: rawURL)],
            outputURL: outputURL
        ))

        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.includedSources, [.microphone])
        XCTAssertEqual(try Data(contentsOf: rawURL), originalData)
        let output = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(output.processingFormat.sampleRate, 48_000, accuracy: 0.5)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertGreaterThan(output.length, 0)
    }

    func testMixAlignsDelayedSecondSourceAndLimitsPeak() async throws {
        let root = temporaryDirectory(named: "Aligned")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let systemURL = root.appending(path: "system.caf")
        let microphoneURL = root.appending(path: "microphone.caf")
        let outputURL = root.appending(path: "mixed.m4a")
        try writeTone(url: systemURL, duration: 0.3, amplitude: 1, channels: 2, frequency: 440)
        try writeTone(url: microphoneURL, duration: 0.2, amplitude: 1, channels: 1, frequency: 880)

        let result = try await AVFoundationOfflineAudioMixer().mix(AudioMixRequest(
            inputs: [
                AudioMixInput(source: .system, url: systemURL),
                AudioMixInput(source: .microphone, url: microphoneURL, timelineOffset: 0.2)
            ],
            outputURL: outputURL
        ))

        XCTAssertFalse(result.degraded)
        XCTAssertEqual(Set(result.includedSources), Set([.system, .microphone]))
        XCTAssertLessThanOrEqual(result.peak, 0.791)
        XCTAssertLessThan(result.finalScale, 1)
        let output = try AVAudioFile(forReading: outputURL)
        let duration = Double(output.length) / output.processingFormat.sampleRate
        XCTAssertGreaterThanOrEqual(duration, 0.38)
        XCTAssertLessThan(duration, 0.46)
    }

    func testUnreadableSourceFallsBackToOtherSource() async throws {
        let root = temporaryDirectory(named: "Fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let validURL = root.appending(path: "system.caf")
        let invalidURL = root.appending(path: "broken.m4a")
        let outputURL = root.appending(path: "mixed.m4a")
        try writeTone(url: validURL, duration: 0.15, amplitude: 0.2, channels: 2)
        try Data("not audio".utf8).write(to: invalidURL)

        let result = try await AVFoundationOfflineAudioMixer().mix(AudioMixRequest(
            inputs: [
                AudioMixInput(source: .system, url: validURL),
                AudioMixInput(source: .microphone, url: invalidURL)
            ],
            outputURL: outputURL
        ))

        XCTAssertTrue(result.degraded)
        XCTAssertEqual(result.includedSources, [.system])
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testFailedMixDoesNotReplaceExistingCompleteRecording() async throws {
        let root = temporaryDirectory(named: "AtomicFailure")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let missingURL = root.appending(path: "missing.m4a")
        let outputURL = root.appending(path: "mixed.m4a")
        let existing = Data("existing complete recording".utf8)
        try existing.write(to: outputURL)

        do {
            _ = try await AVFoundationOfflineAudioMixer().mix(AudioMixRequest(
                inputs: [AudioMixInput(source: .system, url: missingURL)],
                outputURL: outputURL
            ))
            XCTFail("A request with no readable input must fail")
        } catch {
            XCTAssertEqual(error as? AudioMixError, .noReadableInput)
        }

        XCTAssertEqual(try Data(contentsOf: outputURL), existing)
    }

    func testTimelineEpochsCanInsertAnActiveTimeGap() async throws {
        let root = temporaryDirectory(named: "Epochs")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rawURL = root.appending(path: "microphone.caf")
        let outputURL = root.appending(path: "mixed.m4a")
        try writeTone(url: rawURL, duration: 0.2, amplitude: 0.3, channels: 1)
        let sampleRate: Double = 48_000

        let result = try await AVFoundationOfflineAudioMixer().mix(AudioMixRequest(
            inputs: [AudioMixInput(
                source: .microphone,
                url: rawURL,
                epochs: [
                    AudioTimelineEpoch(
                        sourceStartFrame: 0,
                        frameCount: Int64(0.1 * sampleRate),
                        logicalStartFrame: 0
                    ),
                    AudioTimelineEpoch(
                        sourceStartFrame: Int64(0.1 * sampleRate),
                        frameCount: Int64(0.1 * sampleRate),
                        logicalStartFrame: Int64(0.3 * sampleRate)
                    )
                ]
            )],
            outputURL: outputURL,
            expectedDuration: 0.4
        ))

        XCTAssertEqual(result.duration, 0.4, accuracy: 0.04)
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlowAudioMix-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func writeTone(
        url: URL,
        duration: TimeInterval,
        amplitude: Float,
        channels: AVAudioChannelCount,
        frequency: Double = 330
    ) throws {
        let sampleRate: Double = 48_000
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let channelData = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frameCount) {
                channelData[channel][frame] = amplitude * Float(
                    sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
                )
            }
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
