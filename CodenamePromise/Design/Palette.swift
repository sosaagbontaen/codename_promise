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

    /// Top of the A. The same value is in the asset catalog as `AccentColor`, so system
    /// chrome — switches, links, the tint on every unstyled control — picks it up for free.
    static let azure = Color(light: 0x2F6FEE, dark: 0x5B92FF)
    /// Foot of the A.
    static let violet = Color(light: 0x8B3DF5, dark: 0xA970FF)
    /// The R.
    static let ink = Color(light: 0x151C2C, dark: 0xEEF1F8)
    /// The water lines beneath the mark.
    static let ripple = Color(light: 0xC3D2F5, dark: 0x2C3C68)

    /// Identity, never status. See rule 1.
    static let gradient = LinearGradient(
        colors: [azure, violet], startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: Status — exactly three

    /// It reached the destination.
    static let reached = Color(light: 0x16803C, dark: 0x4ADE80)
    /// It has not yet, and that is normal.
    static let waiting = Color(light: 0xB45309, dark: 0xFB923C)
    /// It tried and could not.
    static let failed = Color(light: 0xDC2626, dark: 0xF87171)

    // MARK: Provenance

    /// The model touched this. Not a status — an entry can be formatted and unsynced.
    static let ai = violet
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
            .font(.system(size: 17))
            .lineSpacing(5)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
    }
}
