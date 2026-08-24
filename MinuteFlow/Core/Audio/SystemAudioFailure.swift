import Foundation
import ScreenCaptureKit

struct SystemAudioFailure: Sendable {
    let userMessage: String
    let recoverySuggestion: String
    let isPermissionRelated: Bool

    init(error: any Error) {
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else {
            if error is AudioCaptureError {
                userMessage = error.localizedDescription
            } else {
                userMessage = "系统声音录制失败：\(error.localizedDescription)"
            }
            recoverySuggestion = "请运行五秒录音自检；若仍失败，请保留错误信息。"
            isPermissionRelated = false
            return
        }

        switch nsError.code {
        case -3801:
            userMessage = "系统声音未录制：macOS 未允许当前应用捕获屏幕与系统音频。"
            recoverySuggestion = "请在系统设置中允许当前 MinuteFlow.app，并完全退出后重新打开。"
            isPermissionRelated = true
        case -3802:
            userMessage = "系统音频捕获流启动失败。"
            recoverySuggestion = "请停止其他录屏工具后运行五秒自检。"
            isPermissionRelated = false
        case -3803:
            userMessage = "当前构建缺少系统音频捕获所需能力。"
            recoverySuggestion = "请安装 MinuteFlow 的正式发布包，而不是单独运行二进制文件。"
            isPermissionRelated = false
        case -3813, -3814, -3815:
            userMessage = "没有找到可用的屏幕捕获来源。"
            recoverySuggestion = "请确认至少有一台显示器处于连接和唤醒状态。"
            isPermissionRelated = false
        case -3818:
            userMessage = "macOS 无法启动系统音频录制。"
            recoverySuggestion = "请关闭其他占用系统录音的应用后重试。"
            isPermissionRelated = false
        case -3821:
            userMessage = "系统音频捕获被 macOS 中断。"
            recoverySuggestion = "麦克风录音会继续；请在会后检查系统声音文件。"
            isPermissionRelated = false
        default:
            userMessage = "系统声音录制失败（\(nsError.code)）：\(nsError.localizedDescription)"
            recoverySuggestion = "请运行五秒录音自检并保留该错误代码。"
            isPermissionRelated = false
        }
    }
}
