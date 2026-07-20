import Foundation
import XCTest
@testable import MinuteFlow

final class PermissionManagerTests: XCTestCase {
    func testPassiveStatusNeverRequestsOrProbesScreenCapture() {
        let api = TrackingSystemPrivacyAPI()
        let manager = PermissionManager(systemAPI: api)

        XCTAssertEqual(manager.authorizationStatus(for: .microphone), .notDetermined)
        XCTAssertEqual(manager.authorizationStatus(for: .systemAudio), .unknown)

        XCTAssertEqual(api.microphoneStatusCount, 1)
        XCTAssertEqual(api.preflightCount, 1)
        XCTAssertEqual(api.requestMicrophoneCount, 0)
        XCTAssertEqual(api.requestScreenCount, 0)
        XCTAssertEqual(api.probeCount, 0)
    }

    func testActiveVerificationUsesScreenProbeOnlyAfterExplicitCall() async {
        let api = TrackingSystemPrivacyAPI()
        api.probeResult = true
        let manager = PermissionManager(systemAPI: api)

        let state = await manager.verifyPermission(for: .systemAudio)

        XCTAssertEqual(state, .authorized)
        XCTAssertEqual(api.probeCount, 1)
        XCTAssertEqual(api.requestScreenCount, 0)
    }
}

private final class TrackingSystemPrivacyAPI: SystemPrivacyAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneStatuses = 0
    private var microphoneRequests = 0
    private var preflights = 0
    private var screenRequests = 0
    private var probes = 0
    var probeResult = false

    var microphoneStatusCount: Int { lock.withLock { microphoneStatuses } }
    var requestMicrophoneCount: Int { lock.withLock { microphoneRequests } }
    var preflightCount: Int { lock.withLock { preflights } }
    var requestScreenCount: Int { lock.withLock { screenRequests } }
    var probeCount: Int { lock.withLock { probes } }

    func microphoneStatus() -> PermissionAuthorizationState {
        lock.withLock { microphoneStatuses += 1 }
        return .notDetermined
    }

    func requestMicrophone() async -> Bool {
        lock.withLock { microphoneRequests += 1 }
        return false
    }

    func screenCapturePreflight() -> Bool {
        lock.withLock { preflights += 1 }
        return false
    }

    func requestScreenCapture() -> Bool {
        lock.withLock { screenRequests += 1 }
        return false
    }

    func probeScreenCapture() async throws -> Bool {
        lock.withLock { probes += 1 }
        return probeResult
    }
}
