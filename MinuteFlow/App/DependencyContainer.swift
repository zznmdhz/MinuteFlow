import Foundation

@MainActor
final class DependencyContainer {
    static let shared = DependencyContainer()

    let recordingCoordinator: RecordingCoordinator

    private init() {
        recordingCoordinator = RecordingCoordinator(
            systemAudioService: SystemAudioCaptureService(),
            microphoneService: MicrophoneCaptureService(),
            repository: LocalMeetingRepository(),
            permissionManager: PermissionManager()
        )
    }
}

