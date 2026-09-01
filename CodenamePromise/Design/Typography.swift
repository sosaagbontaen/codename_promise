import SwiftUI
import UIKit

/// The app's voice: Poppins, per the brand sheet.
///
/// One family throughout rather than a display/body pair. Poppins is geometric with circular
/// bowls and generous counters, which is what makes the brand read as friendly rather than
/// corporate — and splitting it against a second face would dilute exactly the quality the
/// mark is trading on.
///
/// Static weights rather than a variable file: the brand sheet names three (Bold, SemiBold,
/// Regular), so shipping those plus Medium keeps the bundle honest about what it uses. It
/// also sidesteps the variable-font trap, where iOS loads the file happily and then serves
/// only its default instance.
enum Type {
    private static func poppins(_ size: CGFloat, _ weight: Weight) -> Font {
        .custom(weight.postScriptName, size: size)
    }

    enum Weight {
        case regular, medium, semibold, bold

        var postScriptName: String {
            switch self {
            case .regular: "Poppins-Regular"
            case .medium: "Poppins-Medium"
            case .semibold: "Poppins-SemiBold"
            case .bold: "Poppins-Bold"
            }
        }
    }

    /// Anything that carries: the wordmark in-app, a day, a sheet heading.
    static func display(_ size: CGFloat, _ weight: Weight = .bold) -> Font {
        poppins(size, weight)
    }

    static func title(_ size: CGFloat = 22) -> Font { poppins(size, .semibold) }

    /// Poppins is geometric, so long paragraphs want a touch more room than a humanist face
    /// would. Callers pair this with `lineSpacing` on the writing surface.
    static func body(_ size: CGFloat = 17, _ weight: Weight = .regular) -> Font {
        poppins(size, weight)
    }

    static func label(_ size: CGFloat = 15, _ weight: Weight = .semibold) -> Font {
        poppins(size, weight)
    }

    static func caption(_ size: CGFloat = 12.5, _ weight: Weight = .medium) -> Font {
        poppins(size, weight)
    }

    // MARK: The user's own words — Literata

    /// What someone actually wrote, as opposed to anything the app says.
    ///
    /// Poppins is a geometric display face: perfectly circular bowls, near-uniform strokes,
    /// a tall x-height with short extenders, and no true italic. All of that is why the
    /// wordmark looks good and why a paragraph of it does not — word shapes flatten out and
    /// there is no rhythm to follow, which is tiring at any length past a caption.
    ///
    /// Literata is drawn for reading on screen, and the split earns its keep twice: it makes
    /// long entries comfortable, and it draws a line between *the app's voice* and *yours*.
    /// Chrome speaks Poppins; your journal does not.
    ///
    /// It is variable on two axes. `opsz` is set to the point size, which is the whole point
    /// of an optical-size axis and is why small text stays open rather than merely shrunk.
    static func journal(_ size: CGFloat = 17, _ weight: CGFloat = 400) -> Font {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: "Literata",
            kCTFontVariationAttribute as UIFontDescriptor.AttributeName: [
                0x77676874: weight,          // 'wght'
                0x6F70737A: Double(size),    // 'opsz'
            ],
        ])
        return Font(UIFont(descriptor: descriptor, size: size))
    }

    /// Everything dictated is timed, and digits that jump around are distracting. Poppins has
    /// no monospaced cut, so this stays system.
    static func mono(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }

    /// A missing font falls back to Helvetica silently, which reads as a design choice rather
    /// than a build problem. Fail loudly in debug instead.
    static func assertAvailable() {
        #if DEBUG
        for family in ["Poppins", "Literata"] where !UIFont.familyNames.contains(family) {
            assertionFailure("\(family) is not registered. Check UIAppFonts and the bundle.")
        }
        #endif
    }
}
