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
    // Mostly Apple's own colours now. The custom navy ground, periwinkle ripples and
    // gradient made the app look like it was trying hard rather than like an iPhone app,
    // so everything except the accent defers to the system, in both light and dark.

    /// The accent: what you can act on, and the app's one colour of its own.
    static let violet = Color(light: 0x6C4CFF, dark: 0x8F76FF)
    static let violetDeep = Color(light: 0x5033D6, dark: 0x6C4CFF)
    static let night = Color(light: 0x0F1115, dark: 0x0F1115)

    /// Kept for the call sites that still ask for it; it is a flat accent now.
    static let gradient = violet

    /// One colour per kind of thing, from the system palette.
    enum Mode {
        static let text = Color(uiColor: .systemBlue)
        static let voice = Color(uiColor: .systemPurple)
        static let photo = Color(uiColor: .systemGreen)
        static let video = Color(uiColor: .systemPink)
        static let extra = Color(uiColor: .systemOrange)
    }

    static let ground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let edge = Color(uiColor: .separator).opacity(0.35)
    static let panel = Color(uiColor: .tertiarySystemGroupedBackground)

    static let ink = Color(uiColor: .label)
    static let muted = Color(uiColor: .secondaryLabel)
    static let azure = violet
    static let ripple = Color(uiColor: .separator)

    // MARK: Status: exactly three

    /// It reached Notion.
    static let reached = Color(uiColor: .systemGreen)
    /// It hasn't yet, and that's normal.
    static let waiting = Color(uiColor: .systemOrange)
    /// It tried and couldn't.
    static let failed = Color(uiColor: .systemRed)

    /// The model touched this.
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
