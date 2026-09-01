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
    // MARK: Identity — the exact values from the brand sheet

    /// The tray, the wordmark's second half, "Dump it".
    static let violet = Color(light: 0x6C4CFF, dark: 0x8F76FF)
    static let violetDeep = Color(light: 0x5033D6, dark: 0x6C4CFF)

    /// The near-black the dark mark sits on.
    static let night = Color(light: 0x0F1115, dark: 0x0F1115)

    static let gradient = LinearGradient(
        colors: [violet, violetDeep], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// The confetti. Each capture mode owns one, which is the whole idea of the mark:
    /// things of different kinds, flying into the same tray.
    ///
    /// **These are identity, never status.** Green here means *photo*, never *it worked* —
    /// which is why the three status colours below are kept separate and never borrow from
    /// this set.
    enum Mode {
        static let text = Color(light: 0x3B82F6, dark: 0x60A5FA)   // blue
        static let voice = Color(light: 0x6C4CFF, dark: 0x8F76FF)  // violet
        static let photo = Color(light: 0x22C55E, dark: 0x4ADE80)  // green
        static let video = Color(light: 0xFF4DA6, dark: 0xFF7CBF)  // pink
        static let extra = Color(light: 0xFFB02E, dark: 0xFFC15C)  // amber
    }

    /// The ground everything sits on.
    ///
    /// `systemGroupedBackground` is the single most recognisable signature of a stock iOS
    /// app, so neither theme uses it. Dark is a blue-black in the Palenight family rather
    /// than the mark's flat #0F1115: a true near-black flattens the confetti and makes the
    /// violet look like it is floating, where a ground with blue already in it holds them.
    static let ground = Color(light: 0xF2F4F7, dark: 0x0E1119)
    /// Cards.
    ///
    /// Was #171B26, about ten points off the ground in each channel - a difference that
    /// survives a screenshot and does not survive a real phone at evening brightness, which
    /// is when this app gets used. Lifted, and paired with `edge` below, because at low
    /// contrast an *outline* is what defines a shape; raising the fill far enough to do the
    /// job on its own would wash the whole screen out.
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C2231)

    /// The hairline around a card. Does most of the work of separating it from the ground.
    static let edge = Color(light: 0x0F1115, dark: 0xFFFFFF).opacity(0.07)

    static let ink = Color(light: 0x0F1115, dark: 0xEDEFF6)
    /// The sheet's grey, for anything secondary.
    static let muted = Color(light: 0x6B7280, dark: 0x8B93A7)
    /// Kept as an alias so call sites meaning "the app's accent" read that way.
    static let azure = violet
    static let ripple = Color(light: 0xDDD6FF, dark: 0x2A2350)

    // MARK: Status — exactly three, and never a confetti colour

    /// It reached Notion.
    static let reached = Color(light: 0x16803C, dark: 0x4ADE80)
    /// It hasn't yet, and that's normal.
    static let waiting = Color(light: 0xB45309, dark: 0xFFB02E)
    /// It tried and couldn't.
    static let failed = Color(light: 0xDC2626, dark: 0xF87171)

    // MARK: Provenance

    /// The model touched this. After the rebrand violet means *the app*, so provenance took
    /// the blue confetti colour rather than competing with the brand.
    static let ai = Mode.text
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
    /// spacing and a reading face are the cheapest things that make long-form typing feel
    /// unhurried instead of cramped &mdash; see `Type.journal` for why it is not Poppins.
    func writingSurface(minHeight: CGFloat = 320) -> some View {
        self
            .font(Type.journal(17))
            .lineSpacing(7)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
    }
}
