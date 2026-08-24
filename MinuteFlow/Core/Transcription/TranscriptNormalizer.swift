import Foundation

enum TranscriptNormalizer {
    static func normalize(_ input: String) -> String {
        var value = input
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        let chineseScalarCount = value.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains(Int($0.value))
        }.count
        if chineseScalarCount > value.count / 4 {
            value = value
                .replacingOccurrences(of: ",", with: "，")
                .replacingOccurrences(of: ";", with: "；")
                .replacingOccurrences(of: ":", with: "：")
                .replacingOccurrences(of: "?", with: "？")
                .replacingOccurrences(of: "!", with: "！")
            if let last = value.last, !"。！？；".contains(last) {
                value.append("。")
            }
        }
        return value
    }
}

