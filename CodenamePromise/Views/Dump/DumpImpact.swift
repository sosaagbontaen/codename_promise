import SwiftUI

/// The shockwave, at app scale.
///
/// A dump that only animates inside one screen is an animation. A dump the whole app feels —
/// tab bar included — is an event. This is the shared bit of state that lets the impact reach
/// past the view that caused it.
///
/// Owned at the root, poked by the Dump screen, read by everything wrapped in `.dumpImpact()`.
@MainActor
@Observable
final class DumpImpact {
    /// True for the single frame the blast is expanding.
    private(set) var blasting = false
    /// Counts blasts, so a view can key an animation to "another one happened".
    private(set) var count = 0

    func blast() {
        count += 1
        blasting = true
        Task {
            try? await Task.sleep(for: .milliseconds(90))
            blasting = false
        }
    }
}

extension View {
    /// Makes this view flinch when a dump lands.
    ///
    /// Three things at once, all brief: the whole app swells about 2.5% and settles, a violet
    /// wash passes over it, and the corners round in slightly — the same trio a camera flash
    /// or a bass hit produces, which is why it reads as force rather than as a transition.
    ///
    /// 2.5% is deliberately restrained. Anything more and the tab bar visibly detaches from
    /// the screen edge, which stops looking like impact and starts looking like a bug.
    func dumpImpact(_ impact: DumpImpact) -> some View {
        self
            .scaleEffect(impact.blasting ? 1.025 : 1.0)
            .animation(
                impact.blasting
                    ? .easeOut(duration: 0.09)
                    : .spring(response: 0.5, dampingFraction: 0.55),
                value: impact.blasting
            )
            .overlay {
                Rectangle()
                    .fill(Brand.violet)
                    .opacity(impact.blasting ? 0.16 : 0)
                    .animation(
                        impact.blasting ? .linear(duration: 0.05) : .easeOut(duration: 0.34),
                        value: impact.blasting
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .blendMode(.plusLighter)
            }
    }
}
