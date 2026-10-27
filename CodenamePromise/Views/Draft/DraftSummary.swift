import CodenamePromiseCore
import Foundation

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
        let rawText = draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String = {
            if let title = draft.content.title, !title.isEmpty { return title }
            let firstLine = rawText.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return firstLine.isEmpty ? "Untitled entry" : firstLine
        }()
        let date = draft.entryDate.representativeDate()

        self.id = draft.id
        self.entryDateKey = draft.entryDateKey
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

    func art(for summary: DraftSummary, store: DraftStore?) -> Art {
        guard summary.mediaCount > 0 else { return .none }
        if let hit = cache[summary.id] { return hit }
        guard let store, let draft = try? store.draft(id: summary.id) else { return .none }
        let media = draft.orderedMedia
        func thumb(_ item: MediaItem) -> DraftSummary.Thumb {
            DraftSummary.Thumb(id: item.id, relativePath: item.relativePath, isVideo: item.kind == .video)
        }
        let art = Art(
            covers: draft.covers.map(thumb),
            thumbs: media.prefix(4).map(thumb),
            hidden: max(0, media.count - 4)
        )
        cache[summary.id] = art
        return art
    }
}
