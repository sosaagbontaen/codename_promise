import SwiftUI

/// What the app looks like while it is listening.
///
/// The mark has a waveform inside the A for a reason: this is a journal you talk to. Until
/// now the recording state was a red capsule with a timer on it, which proves the app is
/// running but not that it can hear you — and "can it hear me" is the only question anyone
/// actually has while speaking into a phone.
///
/// Drawn as bars mirrored around a centre line, newest on the right, so speech reads as
/// something moving toward you rather than a chart filling up.
struct LiveWaveform: View {
    let levels: [CGFloat]
    var barCount: Int = 34
    var tint: Color = .white

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 2.5
            let width = max(1.5, (geometry.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: width, height: height(at: index, in: geometry.size.height))
                        .opacity(opacity(at: index))
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.06), value: levels)
        }
    }

    /// Bars are right-aligned: index 0 is the oldest slot, and a short history leaves the
    /// left end at rest rather than stretching a handful of samples across the whole width.
    private func height(at index: Int, in available: CGFloat) -> CGFloat {
        let offset = barCount - levels.count
        let level = index >= offset ? levels[index - offset] : 0
        let minimum: CGFloat = 3
        return minimum + level * max(0, available - minimum)
    }

    /// The oldest samples fade, so the shape has direction.
    private func opacity(at index: Int) -> Double {
        let offset = barCount - levels.count
        guard index >= offset else { return 0.25 }
        let age = Double(index - offset) / Double(max(1, levels.count))
        return 0.45 + age * 0.55
    }
}
