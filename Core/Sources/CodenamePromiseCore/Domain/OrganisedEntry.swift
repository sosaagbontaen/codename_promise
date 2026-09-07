import Foundation

/// A rambling transcript, arranged into the entry the person would have written.
///
/// This is the product's central claim and it is a different job from `formattedText`, which
/// is a copy-editor forbidden by `wordguard` to change a single word. An organiser is allowed
/// to drop "um" and to put a thought from minute eight beside one from minute one, because
/// speech does not arrive in order and a journal should not read like a transcript.
///
/// What it may never do is lose something quietly, and the way that promise is kept is the
/// reason `sources` exists.
public struct OrganisedEntry: Codable, Hashable, Sendable {
    /// The transcript split into numbered lines, exactly as the server split it.
    ///
    /// Carried rather than recomputed on the device, and that is not redundancy. `sources`
    /// indexes into this array, so a client that split the transcript by its own rules would
    /// resolve every citation to the wrong words. Wrong provenance is worse than none: it
    /// would show somebody a sentence they never said and claim they did.
    public let sentences: [String]

    public let sections: [Section]

    /// Lines discarded as filler, verified as filler by the server rather than taken on the
    /// model's word. Kept so the entry can account for every line it was given.
    public let dropped: [Int]

    /// Which organiser produced this, so a re-organise can be offered only when the prompts
    /// have actually changed. Same purpose as `formatterVersion`.
    public let version: String

    /// One thread of the day.
    public struct Section: Codable, Hashable, Sendable, Identifiable {
        public let heading: String
        public let body: String
        /// 1-based indices into `sentences`: the lines this section was built from.
        ///
        /// **This is the trust mechanism, not a debugging aid.** An app that rewrites your day
        /// and shows you only its version is asking for a kind of trust no product has earned.
        /// The same app that lets you tap a line and read the sentence behind it has earned it
        /// cheaply.
        public let sources: [Int]

        public var id: String { "\(heading)-\(sources.first ?? 0)" }

        public init(heading: String, body: String, sources: [Int]) {
            self.heading = heading
            self.body = body
            self.sources = sources
        }
    }

    public init(sentences: [String], sections: [Section], dropped: [Int], version: String) {
        self.sentences = sentences
        self.sections = sections
        self.dropped = dropped
        self.version = version
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// The lines a section was built from, in the order they were spoken.
    ///
    /// Out-of-range indices are skipped rather than trapped. A stored entry outlives the
    /// build that wrote it, and a citation that has drifted should cost one missing quote,
    /// never a crash in somebody's journal.
    public func spokenLines(for section: Section) -> [String] {
        section.sources.compactMap { index in
            guard index >= 1, index <= sentences.count else { return nil }
            return sentences[index - 1]
        }
    }
}
