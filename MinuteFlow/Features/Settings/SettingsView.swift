import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        TabView {
            Form {
                Picker("默认声音来源", selection: $coordinator.sourceSelection) {
                    ForEach(AudioSourceSelection.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                Text("录音质量：标准（AAC · 48 kHz）")
                    .foregroundStyle(.secondary)
            }
            .padding(22)
            .tabItem { Label("录音", systemImage: "waveform") }

            VStack(alignment: .leading, spacing: 12) {
                Label("本地优先", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("当前版本不会上传音频或会议信息。系统声音与麦克风录音保存在应用数据目录中。")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .tabItem { Label("隐私", systemImage: "hand.raised") }
        }
        .frame(width: 520, height: 260)
    }
}

