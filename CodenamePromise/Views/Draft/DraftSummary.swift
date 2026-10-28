import CodenamePromiseCore
import Foundation
import SwiftData

/// Everything the draft list needs to draw one row, as plain values.
///
/// The list deliberately does **not** hold `EntryDraft` objects. SwiftUI keeps a deleted
/// row's view alive to animate it away and re-evaluates its body while doing so, and a row
/// holding a model then reads an attribute on something SwiftData has already detached:
///
///     Fatal error: This backing data was detached from a context without resolving
///     attribute faults ... \EntryDraft.content
///
/// Emptying the array first only narrows that window, because the retained row view still
/// points at the model. Snapshotting closes it, and it is the rule the rest of the codebase
/// already follows at every other boundary: pass values, never models (ADR-009a).
///
/// **Only cheap fields.** Reading a photo's details is a database load the first time, about
/// 150 microseconds each, so building every entry's photo list on every refresh cost 450ms on
/// a thousand-entry journal, almost all of it for rows nobody was looking at. Photos are read
/// per row as it appears instead, through `EntryArtCache`.
struct DraftSummary: Identifiable, Hashable {
    let id: UUID
    let entryDateKey: String
    /// For ordering entries on the same day, newest first, the way the store does.
    let createdAt: Date
    let title: String
    let preview: String
    /// Everything attached. A count of the relationship, which doesn't load the photos.
    let mediaCount: Int
    let isEmpty: Bool
    /// Anything said or written: typed text, or a recording even before it's transcribed.
    let hasWords: Bool
    /// "Sun, Oct 25".
    let shortDate: String
    /// "Oct 25", for list rows.
    let monthDay: String
    /// "11:32 AM": when it was started, shown under an entry on its day.
    let time: String
    var day: CalendarDay? { CalendarDay(rawValue: entryDateKey) }

    /// A thumbnail's identity and where its bytes are, never the `MediaItem` itself.
    struct Thumb: Identifiable, Hashable {
        let id: UUID
        let relativePath: String
        let isVideo: Bool
    }
}

extension DraftSummary {
    /// The entry, minus the line already serving as its title, with its blank lines closed up.
    static func preview(of rawText: String, titleWasDerived: Bool) -> String {
        var body = Substring(rawText)
        if titleWasDerived, let firstBreak = body.firstIndex(where: \.isNewline) {
            body = body[body.index(after: firstBreak)...]
        } else if titleWasDerived {
            // The whole entry is its own title; there is nothing left to preview.
            return ""
        }
        return body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            // One space, not two. Two was meant to hint at the paragraph break it replaced and
            // just reads as a typo at preview size.
            .joined(separator: " ")
    }

    /// Snapshots a live draft. Only ever called on the main actor while the model is valid.
    init(_ draft: EntryDraft) {
        // The words, not the Markdown, so a list or a bold word doesn't show its markup.
        let rawText = RichDocument.words(ofMarkdown: draft.content.rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            if let title = draft.content.title, !title.isEmpty { return title }
            let firstLine = rawText.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "Untitled entry" : firstLine
        }()
        let date = draft.entryDate.representativeDate()

        self.id = draft.id
        self.entryDateKey = draft.entryDateKey
        self.createdAt = draft.createdAt
        self.title = title
        // What the preview is for is recognising an entry, not reading it: the part the title
        // didn't already say, flattened onto one run of lines.
        self.preview = Self.preview(of: rawText, titleWasDerived: (draft.content.title ?? "").isEmpty)
        self.mediaCount = draft.media.count
        self.isEmpty = draft.content.isEmpty
        self.hasWords = !rawText.isEmpty || !draft.audioCaptures.isEmpty
        self.shortDate = date.formatted(Self.shortDateStyle)
        self.monthDay = date.formatted(Self.monthDayStyle)
        self.time = draft.createdAt.formatted(date: .omitted, time: .shortened)
    }

    // Built once. Format styles are cheap, but a thousand entries times three is not.
    private static let shortDateStyle = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
    private static let monthDayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
}

/// Each entry's photos for display, read when its row first appears and kept until the
/// journal changes.
///
/// A miss used to load the entry and sort every photo it holds just to keep four, from inside
/// a row's body, on the main thread. With forty to sixty photos an entry, scrolling into a
/// stretch of uncached rows read thousands of photos a second. Now a miss asks the store for
/// only the four it shows, plus the covers if any were chosen.
@MainActor
final class EntryArtCache {
    struct Art {
        let covers: [DraftSummary.Thumb]
        let thumbs: [DraftSummary.Thumb]
        let hidden: Int
        static let none = Art(covers: [], thumbs: [], hidden: 0)
    }

    private var cache: [UUID: Art] = [:]

    func clear() { cache.removeAll(keepingCapacity: true) }
    func forget(_ ids: Set<UUID>) { for id in ids { cache[id] = nil } }
    /// Drops entries that no longer exist, keeping everything else.
    func keepOnly(_ ids: Set<UUID>) { cache = cache.filter { ids.contains($0.key) } }

    func art(for summary: DraftSummary, store: DraftStore?) -> Art {
        guard summary.mediaCount > 0 else { return .none }
        if let hit = cache[summary.id] { return hit }
        guard let store, let art = try? Self.read(summary, from: store) else { return .none }
        cache[summary.id] = art
        return art
    }

    private static let shown = 4

    private static func read(_ summary: DraftSummary, from store: DraftStore) throws -> Art {
        let draftId = summary.id
        func thumb(_ item: MediaItem) -> DraftSummary.Thumb {
            DraftSummary.Thumb(id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video)
        }

        var first = FetchDescriptor<MediaItem>(
            predicate: #Predicate { $0.draft?.id == draftId },
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        first.fetchLimit = shown
        // The same order `orderedMedia` gives: position, then id as its tiebreak.
        let thumbs = try store.context.fetch(first)
            .map { (key: ($0.sortIndex, $0.id.uuidString), thumb: thumb($0)) }
            .sorted { $0.key < $1.key }
            .map(\.thumb)

        // Covers are chosen by id on the entry. Only ones still attached to it count, in the
        // order they were picked, as `EntryDraft.covers` has it.
        var coverIds: [UUID] = []
        var one = FetchDescriptor<EntryDraft>(predicate: #Predicate { $0.id == draftId })
        one.fetchLimit = 1
        one.propertiesToFetch = [\.coverMediaIds, \.coverMediaId]
        if let draft = try store.context.fetch(one).first {
            coverIds = draft.coverMediaIds.isEmpty ? (draft.coverMediaId.map { [$0] } ?? []) : draft.coverMediaIds
        }
        var covers: [DraftSummary.Thumb] = []
        if !coverIds.isEmpty {
            let wanted = coverIds
            let found = try store.context.fetch(FetchDescriptor<MediaItem>(
                predicate: #Predicate { wanted.contains($0.id) && $0.draft?.id == draftId }
            ))
            let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            covers = coverIds.compactMap { byId[$0].map(thumb) }
        }

        return Art(covers: covers, thumbs: thumbs, hidden: max(0, summary.mediaCount - shown))
    }
}
