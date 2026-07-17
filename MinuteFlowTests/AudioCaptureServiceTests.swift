import AVFoundation
import XCTest
@testable import MinuteFlow

final class AudioCaptureServiceTests: XCTestCase {
    func testSilenceProducesZeroLevel() {
        let samples = [Float](repeating: 0, count: 128)
        let level = samples.withUnsafeBufferPointer {
            AudioLevelMeter.normalizedLevel(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertEqual(level, 0, accuracy: 0.001)
    }

    func testAudibleSignalProducesVisibleLevel() {
        let samples = [Float](repeating: 0.5, count: 128)
        let level = samples.withUnsafeBufferPointer {
            AudioLevelMeter.normalizedLevel(samples: $0.baseAddress!, count: $0.count)
        }
        XCTAssertGreaterThan(level, 0.8)
        XCTAssertLessThanOrEqual(level, 1)
    }
}

