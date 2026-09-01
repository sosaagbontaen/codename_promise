import SwiftUI

/// The moment the app is named after.
///
/// Pressing "Dump it" was, until now, a state change: the box emptied and a screen appeared.
/// Correct, and nothing happened — which is most of why the app read as flat. The mark shows
/// things *flying into a tray*, and the one gesture the whole product is built around showed
/// none of that.
///
/// So the staged pieces fly. Each one arcs from where it sat toward the tray in the tab bar,
/// shrinking and fading as it lands, on a spring with a per-item delay so they arrive as a
/// handful rather than a block. Then, and only then, the entry opens.
///
/// It is 420ms. Long enough to read as an event, short enough that dumping twice in a row
/// never feels like waiting — which is the line that separates delight from decoration.
struct DumpFlight: View {
    /// One thing in flight: where it started, and what colour it is.
    struct Piece: Identifiable {
        let id = UUID()
        let symbol: String
        let tint: Color
        let origin: CGPoint
        let delay: Double
    }

    let pieces: [Piece]
    /// Where they are all going: the tray in the tab bar.
    let destination: CGPoint
    @Binding var flying: Bool

    var body: some View {
        ZStack {
            ForEach(pieces) { piece in
                Image(systemName: piece.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(piece.tint)
                    .frame(width: 44, height: 44)
                    .background(piece.tint.opacity(0.16), in: Circle())
                    .scaleEffect(flying ? 0.3 : 1)
                    .opacity(flying ? 0 : 1)
                    .position(flying ? destination : piece.origin)
                    .animation(
                        // Slightly under-damped so the arrival has a little weight to it
                        // rather than easing to a stop.
                        .spring(response: 0.42, dampingFraction: 0.72)
                            .delay(piece.delay),
                        value: flying
                    )
            }
        }
        .allowsHitTesting(false)
    }
}

/// The tray reacting to what is about to land in it.
///
/// A tab-bar icon that never changes is furniture. This one fills as soon as there is
/// something staged, so the app is doing something between your inputs rather than only
/// during them.
struct TrayBadge: View {
    let count: Int

    var body: some View {
        ZStack {
            Image(systemName: count > 0 ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
            if count > 0 {
                Circle()
                    .fill(Brand.Mode.video)
                    .frame(width: 8, height: 8)
                    .offset(x: 11, y: -9)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: count)
    }
}
