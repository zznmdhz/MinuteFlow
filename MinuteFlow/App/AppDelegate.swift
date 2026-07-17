import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = DependencyContainer.shared.recordingCoordinator
        guard coordinator.isRecording || coordinator.isPaused else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "录音仍在进行"
        alert.informativeText = "退出前需要停止并安全保存当前录音。是否现在停止并退出？"
        alert.addButton(withTitle: "停止、保存并退出")
        alert.addButton(withTitle: "继续录音")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        Task { @MainActor in
            await coordinator.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
