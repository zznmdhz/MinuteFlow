@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class RecordingDiagnosticsService: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var countdown = 0
    @Published private(set) var systemState: DiagnosticState = .idle("尚未测试")
    @Published private(set) var microphoneState: DiagnosticState = .idle("尚未测试")
    @Published private(set) var lastSystemURL: URL?
    @Published private(set) var lastMicrophoneURL: URL?

    private let permissionManager: PermissionManaging
    private var player: AVAudioPlayer?

    init(permissionManager: PermissionManaging = PermissionManager()) {
        self.permissionManager = permissionManager
    }

    func run() async {
        guard !isRunning else { return }
        isRunning = true
        countdown = 5
        systemState = .testing("准备系统声音测试…")
        microphoneState = .testing("准备麦克风测试…")
        lastSystemURL = nil
        lastMicrophoneURL = nil

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "MinuteFlow-Recording-Test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let systemURL = directory.appending(path: "system-test.m4a")
        let microphoneURL = directory.appending(path: "microphone-test.m4a")

        let systemService = SystemAudioCaptureService()
        let microphoneService = MicrophoneCaptureService()
        let systemPeak = PeakLevelBox()
        let microphonePeak = PeakLevelBox()
        systemService.onLevelUpdate = { level in systemPeak.update(level) }
        microphoneService.onLevelUpdate = { level in microphonePeak.update(level) }

        var systemStarted = false
        var microphoneStarted = false

        if permissionManager.authorizationStatus(for: .systemAudio) == .authorized {
            do {
                try await systemService.start(outputURL: systemURL)
                systemStarted = true
                systemState = .testing("请播放一段电脑声音…")
            } catch {
                let failure = SystemAudioFailure(error: error)
                systemState = .failure("\(failure.userMessage) \(failure.recoverySuggestion)")
            }
        } else {
            let granted = await permissionManager.requestPermission(for: .systemAudio)
            systemState = .failure(granted
                ? "权限已授予；请完全退出并重新打开 MinuteFlow 后再运行自检"
                : "当前应用尚未获得屏幕与系统音频权限；请在系统设置中允许后重启应用")
        }

        if await permissionManager.requestPermission(for: .microphone) {
            do {
                try await microphoneService.start(outputURL: microphoneURL)
                microphoneStarted = true
                microphoneState = .testing("请对着麦克风说话…")
            } catch {
                microphoneState = .failure(error.localizedDescription)
            }
        } else {
            microphoneState = .failure("未获得麦克风权限")
        }

        if systemStarted || microphoneStarted {
            for remaining in stride(from: 5, through: 1, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
            }
        }

        if systemStarted { await systemService.stop() }
        if microphoneStarted { await microphoneService.stop() }

        if systemStarted {
            lastSystemURL = systemURL
            systemState = Self.result(for: systemURL, peak: systemPeak.value, source: "系统声音")
        }
        if microphoneStarted {
            lastMicrophoneURL = microphoneURL
            microphoneState = Self.result(for: microphoneURL, peak: microphonePeak.value, source: "麦克风")
        }

        countdown = 0
        isRunning = false
    }

    func playSystemSample() { play(lastSystemURL) }
    func playMicrophoneSample() { play(lastMicrophoneURL) }

    private func play(_ url: URL?) {
        guard let url else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    private static func result(for url: URL, peak: Float, source: String) -> DiagnosticState {
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard bytes > 512 else { return .failure("\(source)文件未成功写入") }
        if peak < 0.03 {
            return .failure("已写入 \(bytes / 1_024) KB，但没有检测到明显声音")
        }
        return .success("已写入 \(bytes / 1_024) KB · 峰值 \(Int(peak * 100))%")
    }
}

private final class PeakLevelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0

    var value: Float { lock.withLock { peak } }
    func update(_ level: Float) { lock.withLock { peak = max(peak, level) } }
}
