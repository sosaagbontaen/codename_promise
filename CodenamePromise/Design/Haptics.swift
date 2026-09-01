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

    /// Light acknowledgement for a selection that isn't destructive.
    static func picked() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
