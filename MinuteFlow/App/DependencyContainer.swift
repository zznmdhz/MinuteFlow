import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    let recordingCoordinator: RecordingCoordinator
    let modelSettings: ModelSettingsStore

    private init() {
        let settings = ModelSettingsStore()
        modelSettings = settings
        recordingCoordinator = RecordingCoordinator(
            systemAudioService: SystemAudioCaptureService(),
            microphoneService: MicrophoneCaptureService(),
            repository: LocalMeetingRepository(),
            permissionManager: PermissionManager(),
            modelSettings: settings
        )
    }
}
