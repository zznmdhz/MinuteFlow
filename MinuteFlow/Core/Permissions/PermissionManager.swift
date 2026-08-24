import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

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

enum PermissionAuthorizationState: String, Sendable {
    case authorized
    case notDetermined
    case unknown
    case restartRequired
    case denied
    case restricted

    var title: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "尚未请求"
        case .unknown: "待验证"
        case .restartRequired: "需重启生效"
        case .denied: "未授权"
        case .restricted: "受系统限制"
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
    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState
    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState
    @MainActor func openSettings(for kind: PermissionKind)
}

protocol SystemPrivacyAPI: Sendable {
    func microphoneStatus() -> PermissionAuthorizationState
    func requestMicrophone() async -> Bool
    func screenCapturePreflight() -> Bool
    func requestScreenCapture() -> Bool
    func probeScreenCapture() async throws -> Bool
}

struct LiveSystemPrivacyAPI: SystemPrivacyAPI {
    func microphoneStatus() -> PermissionAuthorizationState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    func requestMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted: false
        @unknown default: false
        }
    }

    func screenCapturePreflight() -> Bool { CGPreflightScreenCaptureAccess() }
    func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    func probeScreenCapture() async throws -> Bool {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        return !content.displays.isEmpty
    }
}

final class PermissionManager: PermissionManaging, @unchecked Sendable {
    private let systemAPI: any SystemPrivacyAPI

    init(systemAPI: any SystemPrivacyAPI = LiveSystemPrivacyAPI()) {
        self.systemAPI = systemAPI
    }

    /// Passive status check. It must never display a system permission prompt.
    func authorizationStatus(for kind: PermissionKind) -> PermissionAuthorizationState {
        switch kind {
        case .microphone:
            return systemAPI.microphoneStatus()
        case .systemAudio:
            // A false preflight result can also mean the current process needs a
            // restart. Do not probe ScreenCaptureKit here because that probe may
            // itself display a TCC prompt.
            return systemAPI.screenCapturePreflight() ? .authorized : .unknown
        }
    }

    /// Active verification, called only after an explicit user action.
    func verifyPermission(for kind: PermissionKind) async -> PermissionAuthorizationState {
        if kind == .microphone { return authorizationStatus(for: kind) }
        do {
            return try await systemAPI.probeScreenCapture() ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func requestPermission(for kind: PermissionKind) async -> Bool {
        switch kind {
        case .microphone:
            return await systemAPI.requestMicrophone()
        case .systemAudio:
            if authorizationStatus(for: .systemAudio) == .authorized { return true }
            return systemAPI.requestScreenCapture()
        }
    }

    @MainActor
    func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
