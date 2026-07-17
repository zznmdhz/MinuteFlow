import Foundation

enum RecordingStatus: String, Codable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case saving
    case completed
    case failed

    var title: String {
        switch self {
        case .idle: "准备就绪"
        case .preparing: "准备中"
        case .recording: "正在录音"
        case .paused: "已暂停"
        case .saving: "正在保存"
        case .completed: "已完成"
        case .failed: "录音异常"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .recording, .paused, .saving: true
        default: false
        }
    }
}

