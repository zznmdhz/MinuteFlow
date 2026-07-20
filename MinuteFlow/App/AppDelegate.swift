import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let coordinator = DependencyContainer.shared.recordingCoordinator
        guard coordinator.status.isActive else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        if coordinator.isRecording || coordinator.isPaused {
            alert.messageText = "录音仍在进行"
            alert.informativeText = "退出前需要停止并安全保存原始分轨、逐字稿和完整回放。"
            alert.addButton(withTitle: "停止、保存并退出")
            alert.addButton(withTitle: "继续录音")
        } else {
            alert.messageText = "正在完成录音工作"
            alert.informativeText = "MinuteFlow 正在准备录音或生成完整回放。等待完成可以避免留下未完成状态。"
            alert.addButton(withTitle: "等待完成并退出")
            alert.addButton(withTitle: "取消退出")
        }

        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        Task { @MainActor in
            await coordinator.finishActiveWorkForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
