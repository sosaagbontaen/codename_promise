import Foundation

/// Entries that exist but are not finished.
///
/// `JournalGaps` answers "which days have nothing at all", which turns out to be the smaller
/// half of the question. The common real shape is an entry that *was* started: photos dropped
/// in on the night, meaning to write it up later; or a paragraph typed on the train, meaning
/// to add the pictures when back on wifi. A day-level check can never see either, because the
/// day is covered — there is a page there. It just isn't done.
///
/// So this is deliberately a different axis from `JournalGaps`, not an extension of it: that
/// one walks a calendar looking for holes, this one looks at the entries themselves.
///
/// The tone rule from `JournalGaps` carries over unchanged. This is a worklist of things you
/// meant to come back to, not an audit of things you failed at. Nothing is counted, nothing
/// is scored, and an entry with only a voice recording on it is **not** reported as missing
/// text - see `hasWords`.

/// What an entry is short of.
public enum EntryShortfall: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// Neither words nor attachments. Usually an entry opened and then abandoned.
    case empty
    /// Attachments, no words. "Photos now, write it up later."
    case noText
    /// Words, no attachments. "Wrote it up, add the pictures later."
    case noMedia

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .empty: "Empty"
        case .noText: "No words yet"
        case .noMedia: "No photos yet"
        }
    }

    /// Second person, because the list is an offer to finish something.
    public var rowLabel: String {
        switch self {
        case .empty: "Nothing in it yet"
        case .noText: "Photos, no words"
        case .noMedia: "Words, no photos"
        }
    }

    public var symbol: String {
        switch self {
        case .empty: "circle.dashed"
        case .noText: "text.badge.plus"
        case .noMedia: "photo.badge.plus"
        }
    }

    /// The one an entry is in, or nil when it is complete.
    public static func of(hasWords: Bool, hasMedia: Bool) -> EntryShortfall? {
        switch (hasWords, hasMedia) {
        case (false, false): .empty
        case (false, true): .noText
        case (true, false): .noMedia
        case (true, true): nil
        }
    }
}

/// An entry on this device, reduced to what deciding completeness needs.
///
/// A value rather than an `EntryDraft`, so the rule below is testable without a store and so
/// nothing carries a model across an actor boundary (ADR-009a).
public struct LocalEntryRow: Hashable, Sendable {
    public let id: UUID
    public let day: CalendarDay
    public let title: String?
    /// Typed text, a merged transcript, **or** a recording still waiting to be transcribed.
    ///
    /// That last one matters. Dictated audio is the user's words whether or not the service
    /// has got to it yet, and an app whose founding promise is "never lose what you said"
    /// must not turn round and describe three minutes of speech as an entry with no words
    /// in it. See ADR-002.
    public let hasWords: Bool
    public let hasMedia: Bool
    /// The destination page this entry is bound to, when it has been synced or attached.
    /// Used to fold the two sides of the same entry together rather than list it twice.
    public let linkedPageId: String?

    public init(
        id: UUID, day: CalendarDay, title: String?,
        hasWords: Bool, hasMedia: Bool, linkedPageId: String?
    ) {
        self.id = id
        self.day = day
        self.title = title
        self.hasWords = hasWords
        self.hasMedia = hasMedia
        self.linkedPageId = linkedPageId
    }
}

/// An entry in the destination, classified there and reported as two booleans.
///
/// The server reads the page's blocks to work these out and returns only the verdict — never
/// the text, never the file URLs. `entry-days` holds the line that knowing *whether* a day is
/// written does not require reading what was written; the same line holds here, one level
/// further in.
public struct DestinationEntryRow: Hashable, Sendable {
    public let pageId: String
    public let day: CalendarDay
    public let title: String?
    public let hasWords: Bool
    public let hasMedia: Bool

    public init(pageId: String, day: CalendarDay, title: String?, hasWords: Bool, hasMedia: Bool) {
        self.pageId = pageId
        self.day = day
        self.title = title
        self.hasWords = hasWords
        self.hasMedia = hasMedia
    }
}

/// One unfinished entry, and enough to go and finish it.
public struct ThinEntry: Hashable, Sendable, Identifiable {
    /// Where the entry lives, which decides what tapping it does.
    public enum Source: Hashable, Sendable {
        /// Open this draft.
        case local(UUID)
        /// Start a draft for the day, bound to this page, so what gets added *appends* to
        /// the entry that is already there rather than making a second one for the same day.
        case destination(pageId: String)
    }

    public let source: Source
    public let day: CalendarDay
    public let title: String?
    public let shortfall: EntryShortfall

    public init(source: Source, day: CalendarDay, title: String?, shortfall: EntryShortfall) {
        self.source = source
        self.day = day
        self.title = title
        self.shortfall = shortfall
    }

    public var id: String {
        switch source {
        case .local(let uuid): "local:\(uuid.uuidString)"
        case .destination(let pageId): "page:\(pageId)"
        }
    }

    /// True when this entry has no draft on the device - years of journal written before the
    /// app existed, or a page made on a laptop. Finishing one means creating a draft bound to
    /// that page rather than opening something that is already here.
    public var isInDestinationOnly: Bool {
        if case .destination = source { return true }
        return false
    }

    /// Whether the entry has a name of its own, or is going to be named after its day.
    public var hasOwnTitle: Bool {
        !(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Never "Untitled" — an entry with no title yet is usually exactly the abandoned one
    /// this list exists to surface, and labelling it as a thing called Untitled reads worse
    /// than naming the day.
    public var displayTitle: String {
        guard hasOwnTitle, let title else {
            return day.representativeDate()
                .formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
        return title
    }
}

public enum JournalCompleteness {

    /// Unfinished entries from both sides, newest first, with the same entry counted once.
    ///
    /// **Folding is the load-bearing part.** A draft that has synced exists twice — here and
    /// in Notion — and the two halves can disagree, because the page may have gained photos
    /// that were added in Notion and never came back. Reporting both would double the list;
    /// reporting only the local side would tell someone their entry has no photos while they
    /// are looking at the photos. So a linked pair is merged optimistically: it has words if
    /// *either* side does, and media if *either* side does.
    ///
    /// The merged row keeps the local source, because the local draft is the one that can be
    /// opened and edited.
    ///
    /// - Parameters:
    ///   - destination: nil when the destination was not consulted, which is different from
    ///     an empty array. Nil means local rows are judged on their own; empty means the
    ///     destination genuinely had nothing in the window.
    ///   - matching: which shortfalls to include. Empty returns nothing.
    public static func thinEntries(
        local: [LocalEntryRow],
        destination: [DestinationEntryRow]?,
        matching: Set<EntryShortfall> = Set(EntryShortfall.allCases)
    ) -> [ThinEntry] {
        guard !matching.isEmpty else { return [] }

        var remoteByPage: [String: DestinationEntryRow] = [:]
        for row in destination ?? [] { remoteByPage[row.pageId] = row }

        var found: [ThinEntry] = []
        var foldedPages: Set<String> = []

        for row in local {
            var hasWords = row.hasWords
            var hasMedia = row.hasMedia
            var title = row.title

            if let pageId = row.linkedPageId, let remote = remoteByPage[pageId] {
                foldedPages.insert(pageId)
                hasWords = hasWords || remote.hasWords
                hasMedia = hasMedia || remote.hasMedia
                if title?.isEmpty ?? true { title = remote.title }
            }

            if let shortfall = EntryShortfall.of(hasWords: hasWords, hasMedia: hasMedia),
               matching.contains(shortfall) {
                found.append(ThinEntry(
                    source: .local(row.id), day: row.day, title: title, shortfall: shortfall
                ))
            }
        }

        for row in destination ?? [] where !foldedPages.contains(row.pageId) {
            if let shortfall = EntryShortfall.of(hasWords: row.hasWords, hasMedia: row.hasMedia),
               matching.contains(shortfall) {
                found.append(ThinEntry(
                    source: .destination(pageId: row.pageId),
                    day: row.day, title: row.title, shortfall: shortfall
                ))
            }
        }

        // Newest first, matching the open-days list: the recent one is the one still
        // rememberable, and therefore the only one likely to get finished.
        return found.sorted { left, right in
            left.day == right.day ? left.id < right.id : left.day > right.day
        }
    }
}
