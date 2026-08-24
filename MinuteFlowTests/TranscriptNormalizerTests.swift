import XCTest
@testable import MinuteFlow

final class TranscriptNormalizerTests: XCTestCase {
    func testNormalizesChineseWhitespaceAndPunctuation() {
        XCTAssertEqual(
            TranscriptNormalizer.normalize("  今天  讨论项目进度,明天继续!  "),
            "今天 讨论项目进度，明天继续！"
        )
    }

    func testAddsChineseFinalPunctuationWithoutOverwritingOriginalText() {
        let segment = TranscriptSegment(
            startTime: 0,
            endTime: 1,
            text: "这是原始识别结果",
            source: .microphone,
            isFinal: true
        )

        XCTAssertEqual(TranscriptNormalizer.normalize(segment.text), "这是原始识别结果。")
        XCTAssertEqual(segment.originalText, "这是原始识别结果")
        XCTAssertNil(segment.normalizedText)
    }
}
