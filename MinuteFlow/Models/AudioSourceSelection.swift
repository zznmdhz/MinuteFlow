import Foundation

enum AudioSourceSelection: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case microphone
    case both

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "仅系统声音"
        case .microphone: "仅麦克风"
        case .both: "系统声音 + 麦克风"
        }
    }

    var systemAudioEnabled: Bool { self == .system || self == .both }
    var microphoneEnabled: Bool { self == .microphone || self == .both }
}

