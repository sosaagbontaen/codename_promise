import SwiftUI
import UIKit

/// The app's voice.
///
/// System font is the single loudest reason an app reads as a default iOS app: everything
/// built with it inherits the same texture as Settings, Reminders, and every tutorial project
/// ever shipped. A bundled face changes that in one move, before a single layout is touched.
///
/// Sora for anything that carries — titles, days, the entry heading. Manrope for reading,
/// because a journal is read as much as written and Manrope's wider counters hold up in long
/// paragraphs where Sora would get tiring.
///
/// Both are variable fonts, so one file per family covers the whole weight range. iOS will
/// happily load a variable font and then serve only its *default* instance, which for Manrope
/// is ExtraLight — so weights are selected explicitly through the `wght` axis rather than by
/// asking for a name like "Manrope-Bold" that does not exist in the bundle.
enum Type {
    /// OpenType `wght` axis, as the four-character tag packed into an integer.
    private static let weightAxis = 0x77676874  // 'wght'

    private static func variable(_ family: String, size: CGFloat, weight: CGFloat) -> Font {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: family,
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [weightAxis: weight],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    // MARK: Display — Sora

    /// The list's own name, and nothing else at this size.
    static func display(_ size: CGFloat, _ weight: CGFloat = 700) -> Font {
        variable("Sora", size: size, weight: weight)
    }

    /// A day, an entry title, a sheet heading.
    static func title(_ size: CGFloat = 22) -> Font { display(size, 600) }

    // MARK: Reading — Manrope

    static func body(_ size: CGFloat = 17, _ weight: CGFloat = 400) -> Font {
        variable("Manrope", size: size, weight: weight)
    }

    static func label(_ size: CGFloat = 15, _ weight: CGFloat = 600) -> Font {
        variable("Manrope", size: size, weight: weight)
    }

    static func caption(_ size: CGFloat = 12.5, _ weight: CGFloat = 500) -> Font {
        variable("Manrope", size: size, weight: weight)
    }

    /// Everything that is dictated is timed, and digits that jump are distracting.
    static func mono(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }

    /// Fails loudly in debug if the bundle did not actually register the faces — a missing
    /// font silently falls back to Helvetica, which looks like a design decision rather than
    /// a build problem.
    static func assertAvailable() {
        #if DEBUG
        for family in ["Sora", "Manrope"] where !UIFont.familyNames.contains(family) {
            assertionFailure("\(family) is not registered. Check UIAppFonts and that the file is in the bundle.")
        }
        #endif
    }
}
