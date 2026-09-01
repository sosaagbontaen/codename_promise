import SwiftUI
import UIKit

/// The face your own writing is set in.
///
/// A choice rather than a decision, because this is the one piece of type in the app that is
/// not the app's to have an opinion about. Reading apps have offered this for twenty years
/// for the same reason: the person looking at these words every evening is the only one who
/// knows which of them they can stand.
///
/// It only ever affects *your* text - entry titles, previews, the writing surface. The app's
/// own voice stays the system font and the brand stays Poppins, so switching this cannot make
/// the interface incoherent. See `Type`.
enum JournalFont: String, CaseIterable, Identifiable {
    /// SF Rounded. Warm without being a costume, and it echoes the geometric roundness of the
    /// mark without inheriting Poppins' problems at small sizes.
    case rounded
    /// SF Pro. The one that disappears.
    case sans
    /// New York. Apple's serif, optically sized by the system at every point size, which is
    /// the thing a bundled serif has to reimplement by hand and usually gets wrong.
    case serif
    /// Literata. Kept so the previous look is still there to compare against.
    case book

    static let storageKey = "journalFont"

    /// Read outside a view, because `Type.journal` is a static function called from every
    /// body pass. A `UserDefaults` lookup is a dictionary read; an `@AppStorage` here would
    /// mean threading an environment value through every call site that renders user text.
    static var current: JournalFont {
        UserDefaults.standard.string(forKey: storageKey).flatMap(JournalFont.init) ?? .rounded
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rounded: "Rounded"
        case .sans: "Sans"
        case .serif: "Serif"
        case .book: "Book"
        }
    }

    var note: String {
        switch self {
        case .rounded: "Warm, and closest to the mark"
        case .sans: "Plain and unobtrusive"
        case .serif: "Apple's reading serif"
        case .book: "The bundled one"
        }
    }

    func font(size: CGFloat, weight: CGFloat) -> Font {
        switch self {
        case .rounded: .system(size: size, weight: systemWeight(weight), design: .rounded)
        case .sans: .system(size: size, weight: systemWeight(weight), design: .default)
        case .serif: .system(size: size, weight: systemWeight(weight), design: .serif)
        case .book: Self.literata(size: size, weight: weight)
        }
    }

    private func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case 600...: .semibold
        case 500..<600: .medium
        default: .regular
        }
    }

    /// Literata is variable on two axes, and `opsz` is set to the point size — which is the
    /// whole point of an optical-size axis, and why small text stays open rather than merely
    /// shrunk. iOS serves only a variable font's default instance unless the axes are named
    /// explicitly, so this cannot be done with `.custom`.
    private static func literata(size: CGFloat, weight: CGFloat) -> Font {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Literata",
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [
                0x77676874: weight,          // 'wght'
                0x6F70737A: Double(size),    // 'opsz'
            ],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }
}
