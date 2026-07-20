import Foundation

enum AudioMixState: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case ready
    case degraded
    case failed
}

struct MeetingSession: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let sourceSelection: AudioSourceSelection
    let startTime: Date
    var endTime: Date?
    var duration: TimeInterval
    var recordingStatus: RecordingStatus
    var systemAudioURL: URL?
    var microphoneAudioURL: URL?
    /// Complete playback file. Optional/defaulted so metadata written by older releases decodes.
    var mixedAudioURL: URL? = nil
    var mixState: AudioMixState? = nil
    var mixMessage: String? = nil
    var mixUpdatedAt: Date? = nil
    var transcriptFileURL: URL?
    var summaryFileURL: URL?
    let createdAt: Date
    var updatedAt: Date
}
