import UIKit

/// The physical half of "your words are safe".
///
/// The save state has always been on screen, because not knowing whether your writing is
/// committed is the anxiety this project exists to remove. But a label you have to look at
/// only reassures you if you look at it, and while dictating you are not looking at anything.
/// A tap you can feel does the same job with your eyes closed.
///
/// Deliberately sparse. Haptics stop meaning anything if everything buzzes: these fire only
/// where something genuinely changed hands.
enum Haptics {
    /// Something worked and is now durable: a recording saved, a sync landed.
    static func landed() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Something failed in a way the user needs to notice.
    static func failed() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// A deliberate state change the user asked for — starting a recording, moving photos
    /// to another entry.
    static func committed() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// The dump landing. Heavier than anything else in the app on purpose: this is the one
    /// gesture the product is named after, and it should be the one you can feel through the
    /// table. Followed by a lighter tail so it reads as an impact with a settle rather than
    /// a single buzz.
    static func thud() {
        // Four taps in 160ms, not one. A single impact is a tap however hard it is fired;
        // a burst that starts hard and decays is a *hit* - the ear-and-thumb equivalent of
        // a transient with a tail, which is what makes it read as force rather than
        // notification.
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        let rigid = UIImpactFeedbackGenerator(style: .rigid)
        heavy.prepare(); rigid.prepare()

        heavy.impactOccurred(intensity: 1.0)
        let taps: [(Double, UIImpactFeedbackGenerator, CGFloat)] = [
            (0.045, rigid, 0.95),
            (0.095, heavy, 0.7),
            (0.16,  rigid, 0.45),
        ]
        for (delay, generator, intensity) in taps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                generator.impactOccurred(intensity: intensity)
            }
        }
    }

    /// Light acknowledgement for a selection that isn't destructive.
    static func picked() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
