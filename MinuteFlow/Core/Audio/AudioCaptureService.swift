@preconcurrency import AVFoundation
import Foundation

struct CapturedAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let source: TranscriptSource
}

protocol AudioCaptureService: AnyObject, Sendable {
    var onLevelUpdate: (@Sendable (Float) -> Void)? { get set }
    var onAudioBuffer: (@Sendable (CapturedAudioBuffer) -> Void)? { get set }
    var onError: (@Sendable (Error) -> Void)? { get set }
    var displayName: String { get }

    func start(outputURL: URL) async throws
    func pause()
    func resume()
    func stop() async
}

enum AudioCaptureError: LocalizedError, Sendable {
    case noDisplayAvailable
    case microphoneUnavailable
    case invalidAudioFormat
    case cannotCreateAudioBuffer
    case permissionDenied(source: String)

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            "未找到可用于捕获系统声音的显示器。"
        case .microphoneUnavailable:
            "未找到可用的麦克风输入设备。"
        case .invalidAudioFormat:
            "输入设备返回了不受支持的音频格式。"
        case .cannotCreateAudioBuffer:
            "无法读取系统音频数据。"
        case .permissionDenied(let source):
            "缺少\(source)权限。请前往系统设置 → 隐私与安全性开启权限，然后重新启动 MinuteFlow。"
        }
    }
}
