import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    let recordingCoordinator: RecordingCoordinator
    let modelSettings: ModelSettingsStore
    let aiDiagnostics: AIConnectionDiagnostics
    let recordingDiagnostics: RecordingDiagnosticsService

    private init() {
        let settings = ModelSettingsStore()
        let permissionManager = PermissionManager()
        modelSettings = settings
        aiDiagnostics = AIConnectionDiagnostics()
        recordingDiagnostics = RecordingDiagnosticsService(permissionManager: permissionManager)
        recordingCoordinator = RecordingCoordinator(
            systemAudioService: SystemAudioCaptureService(),
            microphoneService: MicrophoneCaptureService(),
            repository: LocalMeetingRepository(),
            permissionManager: permissionManager,
            modelSettings: settings
        )
    }
}
