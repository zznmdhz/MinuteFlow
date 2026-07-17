import SwiftUI

struct MainView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        HSplitView {
            SidebarView()
                .environmentObject(coordinator)
                .frame(minWidth: 220, idealWidth: 248, maxWidth: 290)

            RecorderView()
                .environmentObject(coordinator)
                .frame(minWidth: 600)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.gradient)
                    Image(systemName: "waveform")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text("MinuteFlow")
                        .font(.system(size: 17, weight: .semibold))
                    Text("本地会议录音")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 22)

            Label("新建录音", systemImage: "record.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)

            Text("最近保存")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 8)

            if coordinator.recentSessions.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "tray")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("录音完成后会显示在这里")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(coordinator.recentSessions.prefix(12)) { session in
                            RecentSessionRow(session: session)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Spacer(minLength: 12)
            Divider()
            Button {
                openSettings()
            } label: {
                Label("设置", systemImage: "gearshape")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }
}

private struct RecentSessionRow: View {
    let session: MeetingSession

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: session.recordingStatus == .completed ? "waveform.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(session.recordingStatus == .completed ? Color.accentColor : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(session.startTime.formatted(date: .abbreviated, time: .shortened)) · \(DurationFormatter.string(from: session.duration))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct RecorderView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header

                if let permissionIssue = coordinator.permissionIssue {
                    PermissionBanner(issue: permissionIssue)
                }

                if let message = coordinator.userMessage {
                    NoticeBanner(message: message)
                }

                recorderCard
                sourcePanel

                HStack(spacing: 6) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("音频仅保存在此 Mac，不会上传到网络")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 34)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.035)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("开始一次清晰、可靠的录音")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("系统声音与麦克风分别保存，任一路异常不影响另一路。")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(status: coordinator.status)
        }
    }

    private var recorderCard: some View {
        VStack(spacing: 20) {
            TextField("会议名称（可选）", text: $coordinator.meetingTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
                .disabled(coordinator.status.isActive)
                .padding(.horizontal, 60)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.06), lineWidth: 16)
                    .frame(width: 168, height: 168)
                Circle()
                    .trim(from: 0, to: coordinator.status.isActive ? 0.78 : 0.18)
                    .stroke(
                        coordinator.isPaused ? Color.orange : Color.red,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 168, height: 168)
                    .animation(.easeInOut(duration: 0.35), value: coordinator.status)

                VStack(spacing: 8) {
                    Image(systemName: coordinator.isPaused ? "pause.fill" : "waveform")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(coordinator.status.isActive ? Color.red : Color.accentColor)
                    Text(DurationFormatter.string(from: coordinator.elapsedTime))
                        .font(.system(size: 27, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                    Text(coordinator.status.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            controls
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    @ViewBuilder
    private var controls: some View {
        if coordinator.isRecording {
            HStack(spacing: 12) {
                Button { coordinator.pauseRecording() } label: {
                    Label("暂停", systemImage: "pause.fill")
                        .frame(minWidth: 86)
                }
                .controlSize(.large)

                Button(role: .destructive) {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
            }
        } else if coordinator.isPaused {
            HStack(spacing: 12) {
                Button { coordinator.resumeRecording() } label: {
                    Label("继续", systemImage: "play.fill")
                        .frame(minWidth: 86)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    Task { await coordinator.stopRecording() }
                } label: {
                    Label("停止并保存", systemImage: "stop.fill")
                        .frame(minWidth: 120)
                }
                .controlSize(.large)
            }
        } else if coordinator.status == .saving || coordinator.status == .preparing {
            ProgressView()
                .controlSize(.large)
        } else {
            Button {
                Task { await coordinator.startRecording() }
            } label: {
                Label("开始录音", systemImage: "record.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(minWidth: 136)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            if coordinator.status == .completed, coordinator.currentSession != nil {
                Button("在 Finder 中显示") { coordinator.openCurrentSessionFolder() }
                    .buttonStyle(.link)
            }
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("声音来源")
                    .font(.headline)
                Spacer()
                Picker("声音来源", selection: $coordinator.sourceSelection) {
                    ForEach(AudioSourceSelection.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(coordinator.status.isActive)
                .frame(width: 190)
            }

            HStack(spacing: 12) {
                SourceCard(
                    icon: "macbook.and.iphone",
                    title: "系统声音",
                    detail: "会议应用与浏览器",
                    enabled: coordinator.sourceSelection.systemAudioEnabled,
                    level: coordinator.systemLevel
                )
                SourceCard(
                    icon: "mic.fill",
                    title: "麦克风",
                    detail: coordinator.microphoneName,
                    enabled: coordinator.sourceSelection.microphoneEnabled,
                    level: coordinator.microphoneLevel
                )
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct SourceCard: View {
    let icon: String
    let title: String
    let detail: String
    let enabled: Bool
    let level: Float

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(enabled ? Color.accentColor : .secondary)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(enabled ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(enabled ? "已启用" : "未启用")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(enabled ? .green : .secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                AudioLevelView(level: enabled ? level : 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .opacity(enabled ? 1 : 0.58)
    }
}

private struct StatusBadge: View {
    let status: RecordingStatus

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status.title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1), in: Capsule())
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .paused: .orange
        case .failed: .red
        case .completed: .green
        default: .secondary
        }
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let issue: PermissionIssue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).font(.subheadline.weight(.semibold))
                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("打开系统设置") { coordinator.openPermissionSettings() }
        }
        .padding(14)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.22)) }
    }
}

private struct NoticeBanner: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.accentColor)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { coordinator.dismissMessage() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

