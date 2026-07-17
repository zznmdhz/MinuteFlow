import Foundation

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
    let createdAt: Date
    var updatedAt: Date
}

