import SwiftUI

@main
struct MinuteFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = DependencyContainer.shared.recordingCoordinator

    var body: some Scene {
        WindowGroup("MinuteFlow", id: "main") {
            MainView()
                .environmentObject(coordinator)
                .frame(minWidth: 840, minHeight: 600)
        }
        .defaultSize(width: 1_020, height: 700)
        .commands {
            CommandGroup(after: .newItem) {
                Button("开始新录音") {
                    Task { await coordinator.startRecording() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!coordinator.canStart)

                Button(coordinator.isPaused ? "继续录音" : "暂停录音") {
                    coordinator.isPaused
                        ? coordinator.resumeRecording()
                        : coordinator.pauseRecording()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!coordinator.isRecording && !coordinator.isPaused)

                Button("停止并保存") {
                    Task { await coordinator.stopRecording() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!coordinator.isRecording && !coordinator.isPaused)
            }
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(coordinator)
        } label: {
            Image(systemName: coordinator.status.isActive ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(coordinator.status.isActive ? .red : .primary, .primary)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(coordinator)
        }
    }
}
