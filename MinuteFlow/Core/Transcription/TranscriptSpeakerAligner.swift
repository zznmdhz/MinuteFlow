import Foundation

enum TranscriptSpeakerAligner {
    static func align(
        segments: [TranscriptSegment],
        with result: SpeakerDiarizationResult
    ) -> [TranscriptSegment] {
        let finalSegments = segments.filter(\.isFinal).sorted { $0.startTime < $1.startTime }
        guard !finalSegments.isEmpty, !result.turns.isEmpty else { return finalSegments }

        if result.speakerCount <= 1 {
            return finalSegments.map { segment in
                var copy = segment
                copy.speakerID = result.turns.first?.speakerID ?? "speaker-1"
                copy.recognitionFragments = copy.recognitionFragments?.map { fragment in
                    var updated = fragment
                    updated.speakerID = copy.speakerID
                    return updated
                }
                return copy
            }
        }

        var timeline: [TranscriptSegment] = []
        for segment in finalSegments {
            let units = recognitionUnits(from: segment)
            for unit in units {
                let speakerID = dominantSpeaker(
                    start: unit.startTime,
                    end: unit.endTime,
                    turns: result.turns
                )
                let cleanedText = ASRTextSanitizer.clean(unit.originalText)
                guard !cleanedText.isEmpty else { continue }
                let fragment = TranscriptRecognitionFragment(
                    id: unit.id,
                    startTime: unit.startTime,
                    endTime: unit.endTime,
                    originalText: cleanedText,
                    boundaryReason: unit.boundaryReason,
                    overlapBefore: unit.overlapBefore,
                    speakerID: speakerID
                )
                let next = TranscriptSegment(
                    id: unit.id,
                    startTime: unit.startTime,
                    endTime: unit.endTime,
                    text: cleanedText,
                    source: segment.source,
                    isFinal: true,
                    originalText: cleanedText,
                    recognitionFragments: [fragment],
                    boundaryReason: unit.boundaryReason,
                    speakerID: speakerID
                )
                appendOrMerge(next, into: &timeline)
            }
        }
        return timeline
    }

    private static func recognitionUnits(from segment: TranscriptSegment) -> [TranscriptRecognitionFragment] {
        if let fragments = segment.recognitionFragments, !fragments.isEmpty { return fragments }
        return [TranscriptRecognitionFragment(
            id: segment.id,
            startTime: segment.startTime,
            endTime: segment.endTime,
            originalText: segment.originalText ?? segment.text,
            boundaryReason: segment.boundaryReason ?? .legacyUnknown,
            speakerID: segment.speakerID
        )]
    }

    private static func dominantSpeaker(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn]
    ) -> String? {
        let overlaps = turns.map { turn -> (String, TimeInterval) in
            let overlap = max(0, min(end, turn.endTime) - max(start, turn.startTime))
            return (turn.speakerID, overlap)
        }
        return overlaps.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil }
            ?? turns.min { abs(($0.startTime + $0.endTime) / 2 - start) < abs(($1.startTime + $1.endTime) / 2 - start) }?.speakerID
    }

    private static func appendOrMerge(_ next: TranscriptSegment, into result: inout [TranscriptSegment]) {
        guard var previous = result.last else {
            result.append(next)
            return
        }
        let gap = next.startTime - previous.endTime
        let combinedDuration = next.endTime - previous.startTime
        guard previous.speakerID == next.speakerID, gap <= 1.2, combinedDuration <= 60 else {
            result.append(next)
            return
        }
        previous.endTime = max(previous.endTime, next.endTime)
        previous.text = TranscriptTextStitcher.stitch(previous.text, next.text)
        previous.originalText = TranscriptTextStitcher.stitch(
            previous.originalText ?? previous.text,
            next.originalText ?? next.text
        )
        previous.recognitionFragments = (previous.recognitionFragments ?? []) + (next.recognitionFragments ?? [])
        previous.boundaryReason = next.boundaryReason
        result[result.count - 1] = previous
    }
}

enum ASRTextSanitizer {
    static func clean(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(
            of: #"(?:\s*<chinese>\s*){2,}"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum TranscriptTextStitcher {
    static func stitch(_ previous: String, _ next: String) -> String {
        let left = Array(previous)
        let right = Array(next)
        let maximum = min(48, left.count, right.count)
        if maximum >= 2 {
            for count in stride(from: maximum, through: 2, by: -1) {
                if String(left.suffix(count)).lowercased() == String(right.prefix(count)).lowercased() {
                    return previous + separator(previous, String(right.dropFirst(count))) + String(right.dropFirst(count))
                }
            }
        }
        return previous + separator(previous, next) + next
    }

    private static func separator(_ previous: String, _ next: String) -> String {
        guard let left = previous.last, let right = next.first else { return "" }
        let leftASCII = left.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        let rightASCII = right.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        return leftASCII && rightASCII ? " " : ""
    }
}
