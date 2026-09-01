import SwiftUI

/// The app's colours, in one place.
///
/// Read off the mark: an azure-to-violet gradient, a deep navy, and pale periwinkle ripples.
/// Before this existed the same eight colours were spelled out as literals across eight
/// files, which is how "sync failed" and "not synced yet" ended up the same shade of orange
/// — a failure and a perfectly ordinary pending state looking identical.
///
/// Two rules hold the system together:
///
/// 1. **The gradient is identity, never status.** It marks moments that say *this app*: an
///    empty state, a first run. It never encodes whether something worked.
/// 2. **Status has exactly three colours.** Green reached the destination, amber has not yet,
///    red tried and failed. Anything that is not one of those three is not status.
///
/// `Brand.ai` is the one deliberate exception to rule 2's tidiness: violet marks what the
/// model touched. It predates the logo, users already read it that way, and provenance is
/// not the same question as success.
enum Brand {
    // MARK: Identity

    /// The tray, the wordmark's second half, the "Dump it" button. Sampled from the concept:
    /// the single most-used saturated colour in it.
    static let violet = Color(light: 0x603CE4, dark: 0x8265FF)
    /// Deeper, for pressed states and the gradient's tail.
    static let violetDeep = Color(light: 0x4A28C4, dark: 0x6B4AE8)

    /// The ground the mark is drawn on. Not a neutral grey - a near-black with the same blue
    /// in it as the violet, which is what stops the dark theme looking like a default.
    static let night = Color(light: 0x090D19, dark: 0x090D19)

    static let gradient = LinearGradient(
        colors: [violet, violetDeep], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// The confetti. Each capture mode owns one, which is the whole idea of the mark: things
    /// of different kinds, flying into the same tray.
    ///
    /// These are identity, not status - a green here means "photo", never "it worked". That
    /// is why status keeps its own three colours below and never borrows from this set.
    enum Mode {
        static let text = Color(light: 0x3B82F6, dark: 0x60A5FA)
        static let voice = Color(light: 0x8B5CF6, dark: 0xA78BFA)
        static let photo = Color(light: 0x22C55E, dark: 0x4ADE80)
        static let video = Color(light: 0xEC4899, dark: 0xF472B6)
        static let extra = Color(light: 0xF97316, dark: 0xFB923C)
    }

    /// The ground everything sits on.
    ///
    /// `systemGroupedBackground` is the single most recognisable signature of a stock iOS
    /// app. This is the same idea pulled toward the mark's violet: still recedes, no longer
    /// anonymous.
    static let ground = Color(light: 0xF4F3FB, dark: 0x0B0F1C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x141928)

    /// The R-of-the-old-mark equivalent: text that carries.
    static let ink = Color(light: 0x12141F, dark: 0xF2F3F8)
    /// Kept as an alias so call sites that mean "the app's accent" read that way.
    static let azure = violet
    static let ripple = Color(light: 0xD8D2F7, dark: 0x2A2350)

    // MARK: Status - exactly three, and never a confetti colour

    /// It reached the destination.
    static let reached = Color(light: 0x16803C, dark: 0x4ADE80)
    /// It has not yet, and that is normal.
    static let waiting = Color(light: 0xB45309, dark: 0xFB923C)
    /// It tried and could not.
    static let failed = Color(light: 0xDC2626, dark: 0xF87171)

    // MARK: Provenance

    /// The model touched this. Distinct from the brand violet on purpose: after the rebrand
    /// violet means *the app*, so provenance moved to the voice confetti colour, which is
    /// adjacent enough to stay familiar and different enough not to read as chrome.
    static let ai = Mode.voice
}

extension Color {
    /// A colour that resolves per appearance, without an asset-catalog entry for every token.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    /// The surface someone actually writes on.
    ///
    /// A journal is read as much as it is written, often years later, and the default
    /// `TextEditor` metrics are tuned for form fields rather than for paragraphs. Line
    /// spacing and a slightly larger face are the cheapest thing that makes long-form typing
    /// feel unhurried instead of cramped.
    func writingSurface(minHeight: CGFloat = 320) -> some View {
        self
            .font(Type.body(17))
            .lineSpacing(6)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
    }
}
