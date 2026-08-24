import Foundation

enum AudioMixState: String, Codable, Equatable, Sendable {
    case queued
    case processing
    case ready
    case degraded
    case failed
}

struct MeetingLocation: Codable, Equatable, Sendable {
    var displayName: String
    var latitude: Double
    var longitude: Double
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
    /// AI-arranged readable Markdown. Optional for older meeting metadata.
    var formattedDocumentFileURL: URL? = nil
    var diarizationFileURL: URL? = nil
    var speakerNames: [String: String]? = nil
    var silentSources: [TranscriptSource]? = nil
    /// Human-readable start location captured with explicit macOS permission.
    /// Optional so all older metadata remains decodable.
    var location: MeetingLocation? = nil
    /// Distinguishes the date-based placeholder from a title supplied by the user
    /// or generated from the transcript by the configured text model.
    var titleWasAutomaticallyGenerated: Bool? = nil
    /// Set only after the saved recording reached the end successfully. This
    /// avoids treating trailing silence as an endlessly resumable gap.
    var postTranscriptionCompletedAt: Date? = nil
    var postTranscriptionCompletedDuration: TimeInterval? = nil
    let createdAt: Date
    var updatedAt: Date
}
