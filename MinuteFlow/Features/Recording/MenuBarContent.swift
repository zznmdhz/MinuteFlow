import AppKit
import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if coordinator.status.isActive {
            Text("\(coordinator.status.title) · \(DurationFormatter.string(from: coordinator.elapsedTime))")
        } else {
            Text("MinuteFlow · \(coordinator.status.title)")
        }

        Divider()

        if coordinator.canStart {
            Button("开始新录音") {
                Task { await coordinator.startRecording() }
            }
        }

        if coordinator.isRecording {
            Button("暂停录音") { coordinator.pauseRecording() }
        } else if coordinator.isPaused {
            Button("继续录音") { coordinator.resumeRecording() }
        }

        if coordinator.isRecording || coordinator.isPaused {
            Button("停止并保存") {
                Task { await coordinator.stopRecording() }
            }
        }

        Divider()

        Button("打开主窗口") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        if coordinator.currentSession != nil {
            Button("显示录音文件") { coordinator.openCurrentSessionFolder() }
        }

        SettingsLink { Text("设置…") }
        Divider()
        Button("退出 MinuteFlow") { NSApplication.shared.terminate(nil) }
    }
}

