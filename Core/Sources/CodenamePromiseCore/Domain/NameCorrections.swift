import Foundation

/// Spellings the transcriber gets wrong the same way every time.
///
/// Speech-to-text has no way to know that the Lizzy in your life is a Lizzy and not a Lizzie,
/// and it will not learn. It picks whichever spelling is commoner in its training data and
/// produces that one, forever, in every entry. Which means the name of someone you love is
/// wrong in your journal in perpetuity, and the only fix is to retype it every single time.
///
/// So the app is told once. A correction is a pair — what the machine hears, what you meant —
/// and it is applied to a transcript before it ever becomes part of an entry.
///
/// **This does not change what you said.** It is the opposite: the person said "Lizzy" and the
/// machine wrote "Lizzie", so correcting it makes the transcript *more* faithful to the
/// recording, not less. That is why this is allowed to touch `rawText`, which nothing else
/// is. The audio remains the record of what was actually said.
public struct NameCorrection: Sendable, Hashable, Codable, Identifiable {
    public var id: String { heard.lowercased() }

    /// What comes back from the transcriber.
    public let heard: String
    /// What it should have been.
    public let meant: String

    public init(heard: String, meant: String) {
        self.heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        self.meant = meant.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isUsable: Bool {
        !heard.isEmpty && !meant.isEmpty && heard.lowercased() != meant.lowercased()
    }
}

public struct NameCorrections: Sendable, Hashable, Codable {
    public private(set) var corrections: [NameCorrection]

    public init(_ corrections: [NameCorrection] = []) {
        self.corrections = corrections.filter(\.isUsable)
    }

    public var isEmpty: Bool { corrections.isEmpty }
    public var count: Int { corrections.count }

    public mutating func add(_ correction: NameCorrection) {
        guard correction.isUsable else { return }
        // One rule per heard spelling. Adding "Lizzie -> Elizabeth" after
        // "Lizzie -> Lizzy" replaces it rather than leaving two rules where the second
        // could never fire.
        corrections.removeAll { $0.id == correction.id }
        corrections.append(correction)
    }

    public mutating func remove(_ id: String) {
        corrections.removeAll { $0.id == id }
    }

    /// Rewrites a transcript, leaving everything that is not a whole-word match alone.
    ///
    /// Whole words only, which is the whole safety story here. A plain find-and-replace of
    /// "Aiden" with "Aidan" also rewrites "Aidenfield" and the middle of anything else that
    /// happens to contain those five letters, and a journal is not a place to be quietly
    /// corrupting words nobody asked about.
    ///
    /// Matching ignores case and replacement does not: what you typed is what you get. A name
    /// has one spelling wherever it appears, and guessing at capitalisation from context is a
    /// cleverness that would eventually be wrong about someone's name — which is the exact
    /// problem this exists to end.
    ///
    /// One pass, so no correction can be fed the output of another. Running the rules in
    /// sequence would turn "Ann" into "Anna" and then, if a second rule mentioned Anna, into
    /// "Annabel" — a name nobody typed, produced by two rules that individually looked right.
    public func apply(to text: String) -> String {
        transform(text) { _, replacement in replacement }
    }

    /// How many whole-word matches the corrections would make. For telling somebody what an
    /// action is about to do before they agree to it.
    public func matchCount(in text: String) -> Int {
        guard let regex = Self.regex(for: corrections), !text.isEmpty else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func transform(
        _ text: String, _ replace: (String, String) -> String
    ) -> String {
        guard let regex = Self.regex(for: corrections), !text.isEmpty else { return text }
        let meanings = Dictionary(
            corrections.map { ($0.heard.lowercased(), $0.meant) },
            uniquingKeysWith: { _, latest in latest }
        )

        var result = text
        let matches = regex.matches(
            in: text, range: NSRange(text.startIndex..., in: text)
        )
        // Back to front, so replacing one match cannot shift the range of the next.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let matched = String(result[range])
            guard let meant = meanings[matched.lowercased()] else { continue }
            result.replaceSubrange(range, with: replace(matched, meant))
        }
        return result
    }

    /// One pattern for every correction at once.
    ///
    /// `\b` is the obvious way to say "whole word" and is wrong at either end of a name that
    /// does not begin or end with a letter: in "J.R. arrived" there is no boundary between
    /// the full stop and the space, so `J\.R\.\b` matches nothing. Asserting that the
    /// neighbouring character is not part of a word says what was actually meant, whatever
    /// the name happens to start and end with.
    private static func regex(for corrections: [NameCorrection]) -> NSRegularExpression? {
        guard !corrections.isEmpty else { return nil }
        // Longest first: with rules for both "Sam" and "Sam Osa", alternation takes whichever
        // it is offered first, and the shorter one would win and leave " Osa" stranded.
        let alternatives = corrections
            .sorted { $0.heard.count > $1.heard.count }
            .map { NSRegularExpression.escapedPattern(for: $0.heard) }
        let pattern = "(?<!\\w)(?:" + alternatives.joined(separator: "|") + ")(?!\\w)"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
