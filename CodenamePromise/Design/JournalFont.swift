import SwiftUI

/// The face your own writing is set in.
///
/// A choice rather than a decision, because this is the one piece of type in the app that is
/// not the app's to have an opinion about. Reading apps have offered this for twenty years for
/// the same reason: the person looking at these words every evening is the only one who knows
/// which of them they can stand.
///
/// Two options, both from the system. A bundled face was tried and dropped - it cost 955KB,
/// it had to reimplement optical sizing by hand, and choosing it for somebody was the mistake
/// this setting exists to stop repeating.
///
/// It only ever affects *your* text - entry titles, previews, the writing surface. The app's
/// own voice stays the system font and the brand stays Poppins, so switching this cannot make
/// the interface incoherent. See `Type`.
enum JournalFont: String, CaseIterable, Identifiable {
    /// SF Pro. The one that disappears - and the same face as the app's own labels, which
    /// means picking it trades away the your-words-versus-our-words distinction. That is a
    /// legitimate thing to want; plenty of people would rather one voice than two.
    case sans
    /// New York. Apple's serif, optically sized by the system at every point size, which is
    /// what a bundled serif has to reimplement by hand and usually gets wrong. Keeps the
    /// distinction between what you wrote and what the app is saying.
    case serif

    static let storageKey = "journalFont"

    /// Read outside a view, because `Type.journal` is a static function called from every
    /// body pass. A `UserDefaults` lookup is a dictionary read; an `@AppStorage` here would
    /// mean threading an environment value through every call site that renders user text.
    ///
    /// An unrecognised stored value falls back to the default, which is what quietly migrates
    /// anyone who had picked one of the options that no longer exists.
    static var current: JournalFont {
        UserDefaults.standard.string(forKey: storageKey).flatMap(JournalFont.init) ?? .sans
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans: "Sans"
        case .serif: "Serif"
        }
    }

    /// Says what the typeface *is*, not how it feels.
    var note: String {
        switch self {
        case .sans: "SF Pro"
        case .serif: "New York"
        }
    }

    func font(size: CGFloat, weight: CGFloat) -> Font {
        .system(size: size, weight: systemWeight(weight), design: self == .serif ? .serif : .default)
    }

    /// `weight` is numeric at the call sites because it once drove a variable font's `wght`
    /// axis. Kept rather than churned through every caller for no behavioural gain.
    private func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case 600...: .semibold
        case 500..<600: .medium
        default: .regular
        }
    }
}
