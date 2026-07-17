import AVFoundation
import AppKit
import CoreGraphics
import Foundation

enum PermissionKind: String, Sendable {
    case microphone
    case systemAudio

    var title: String {
        switch self {
        case .microphone: "麦克风"
        case .systemAudio: "屏幕与系统音频录制"
        }
    }

    var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .systemAudio:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }
}

struct PermissionIssue: Identifiable, Equatable, Sendable {
    let kind: PermissionKind
    let detail: String
    var id: String { kind.rawValue }

    var title: String { "需要\(kind.title)权限" }
}

protocol PermissionManaging: AnyObject, Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool
    @MainActor func openSettings(for kind: PermissionKind)
}

final class PermissionManager: PermissionManaging, @unchecked Sendable {
    func requestPermission(for kind: PermissionKind) async -> Bool {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return true
            case .notDetermined:
                return await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted:
                return false
            @unknown default:
                return false
            }
        case .systemAudio:
            if CGPreflightScreenCaptureAccess() { return true }
            return CGRequestScreenCaptureAccess()
        }
    }

    @MainActor
    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
