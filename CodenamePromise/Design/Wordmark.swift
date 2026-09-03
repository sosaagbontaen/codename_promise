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
        // Scales rather than truncating, and deliberately does *not* take a fixed size.
        //
        // fixedSize was here to stop the toolbar squeezing this into "Du...Not...", and it
        // worked by making the item unshrinkable - which left the toolbar with exactly one
        // remaining move when the leading and trailing groups did not leave room: drop it.
        // On a phone with four other toolbar items and larger text, the wordmark simply was
        // not there, which is a worse failure than a truncated one and much harder to spot,
        // because nothing is drawn to notice.
        //
        // lineLimit plus minimumScaleFactor gets the original result honestly: it shrinks to
        // 75% before it will lose a letter, and it can always be given less width than it
        // wants, so it is never the thing that has to disappear.
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
