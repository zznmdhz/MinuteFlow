import SwiftUI

struct AudioLevelView: View {
    let level: Float
    var barCount = 22

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                let threshold = Float(index + 1) / Float(barCount)
                Capsule(style: .continuous)
                    .fill(threshold <= level ? activeColor(for: threshold) : Color.primary.opacity(0.09))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 7)
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(level * 100)) 百分比")
    }

    private func activeColor(for threshold: Float) -> Color {
        if threshold > 0.85 { return .red }
        if threshold > 0.68 { return .orange }
        return Color.accentColor
    }
}

