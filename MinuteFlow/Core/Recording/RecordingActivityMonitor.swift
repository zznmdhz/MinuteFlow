import Foundation

/// Audio callbacks only update this small, lock-protected snapshot. They never enqueue UI work.
final class RecordingActivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var system: Float = 0
    private var microphone: Float = 0
    private var lastSound: TimeInterval = 0

    func reset(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            system = 0
            microphone = 0
            lastSound = time
        }
    }

    func receive(_ level: Float, microphone isMicrophone: Bool,
                 at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard level.isFinite else { return }
        lock.withLock {
            let bounded = min(max(level, 0), 1)
            if isMicrophone { microphone = max(microphone, bounded) }
            else { system = max(system, bounded) }
            // -48 dB RMS. Treat any audible source as activity, not ASR success.
            // Music/noise can keep recording active; this is deliberately conservative.
            if bounded >= 0.2 { lastSound = max(lastSound, time) }
        }
    }

    func sample(at time: TimeInterval = ProcessInfo.processInfo.systemUptime)
        -> (system: Float, microphone: Float, silentFor: TimeInterval) {
        lock.withLock {
            let result = (system, microphone, max(0, time - lastSound))
            system = 0
            microphone = 0
            return result
        }
    }
}
