import SwiftUI

/// The wordmark, set the way the brand sheet sets it.
///
/// "Dump" in the ink colour, "Notes" in violet — on both grounds, which is the whole point of
/// the two-tone: it survives light and dark without needing two lockups. Rendering the name
/// as flat text everywhere was the one place the app still said DumpNotes without *looking*
/// like DumpNotes.
///
/// Split from `Bundle.main.appDisplayName` rather than hard-coded, so a rename still only
/// touches `CFBundleDisplayName`. If the name stops being two words in camel case, it simply
/// renders whole in ink, which is the safe failure.
struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        let (head, tail) = Self.split(Bundle.main.appDisplayName)
        return HStack(spacing: 0) {
            Text(head).foregroundStyle(Brand.ink)
            Text(tail).foregroundStyle(Brand.violet)
        }
        .font(Type.display(size, .bold))
        .tracking(-0.3)
        .lineLimit(1)
        // A toolbar squeezes its principal item between the leading and trailing groups and
        // will happily truncate it - "Du...Not..." - rather than let it claim the width it
        // needs. fixedSize takes the intrinsic width; the scale factor is the fallback when
        // even that will not fit, so it shrinks instead of losing letters.
        .fixedSize(horizontal: true, vertical: false)
        .minimumScaleFactor(0.75)
        .accessibilityElement()
        .accessibilityLabel(Bundle.main.appDisplayName)
    }

    /// Splits at the interior capital: DumpNotes -> ("Dump", "Notes").
    static func split(_ name: String) -> (String, String) {
        let chars = Array(name)
        guard let idx = chars.dropFirst().firstIndex(where: { $0.isUppercase }) else {
            return (name, "")
        }
        return (String(chars[..<idx]), String(chars[idx...]))
    }
}
