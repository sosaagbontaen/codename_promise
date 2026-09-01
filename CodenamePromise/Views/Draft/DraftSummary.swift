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
struct DraftSummary: Identifiable, Hashable {
    let id: UUID
    let entryDateKey: String
    let title: String
    /// When the entry was *started*, phrased so it cannot be misread as a timestamp for the
    /// day it is filed under. A time of day when those agree, "added Sep 1" when they do not.
    /// Never last-modified: an entry you tidied a typo in did not happen at 11pm.
    let time: String
    let preview: String
    let thumbnails: [Thumb]
    let hiddenThumbnailCount: Int
    /// Everything attached, not just what the collage shows.
    let mediaCount: Int
    let pendingRecordings: Int
    let isFormatted: Bool
    let isEmpty: Bool
    let sync: SyncBadge

    /// A thumbnail's identity and where its bytes are — never the `MediaItem` itself.
    struct Thumb: Identifiable, Hashable {
        let id: UUID
        let relativePath: String
        let isVideo: Bool
    }

    /// What the row should say about this entry's destination.
    ///
    /// Resolved once, here, rather than recomputed in the row — the row has no model to ask.
    enum SyncBadge: Hashable {
        case hidden
        case syncing
        case failed
        case synced
        case unsyncedChanges
        case notSynced
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
            .joined(separator: "  ")
    }

    /// Snapshots a live draft. Only ever called on the main actor while the model is valid.
    init(_ draft: EntryDraft, thumbnailLimit: Int) {
        let media = draft.orderedMedia
        let rawText = draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedTitle: String = {
            if let title = draft.content.title, !title.isEmpty { return title }
            let firstLine = rawText
                .split(separator: "\n", omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? ""
            return firstLine.isEmpty ? "Untitled entry" : firstLine
        }()

        self.id = draft.id
        self.entryDateKey = draft.entryDateKey
        self.title = resolvedTitle
        // A bare time is only honest when it belongs to the day the card is filed under.
        //
        // This is `createdAt` - when the entry was started - while the heading above it is
        // `entryDateKey`, the day the entry is *about*. Those are usually the same day and
        // the time then reads exactly as it should: which entry came first that evening.
        //
        // They come apart the moment somebody backfills. Write up last Tuesday today and the
        // card sits under Tuesday showing a time from this afternoon, which is not ambiguous
        // so much as wrong - it looks like a timestamp for Tuesday. So when the two disagree
        // the card says when it was *added* instead, with the date, and stops pretending.
        let startedOn = CalendarDay(date: draft.createdAt)
        self.time = startedOn.rawValue == draft.entryDateKey
            ? draft.createdAt.formatted(date: .omitted, time: .shortened)
            : "added \(draft.createdAt.formatted(.dateTime.month(.abbreviated).day()))"
        // What the preview is *for* is recognising an entry, not reading it - so it gets the
        // part the title did not already say, flattened onto one run of lines.
        //
        // Two things were costing a card most of its preview. When an entry has no title of
        // its own the title is its first line, and the preview then began by repeating that
        // line verbatim. And blank lines between paragraphs came through intact, so with two
        // lines to spend, one went on a title already above it and the other on nothing.
        self.preview = Self.preview(
            of: rawText, titleWasDerived: (draft.content.title ?? "").isEmpty
        )
        self.thumbnails = media.prefix(thumbnailLimit).map {
            Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
        }
        self.hiddenThumbnailCount = max(0, media.count - thumbnailLimit)
        self.mediaCount = media.count
        self.pendingRecordings = draft.audioCaptures.filter { !$0.isSafeToDelete }.count
        self.isFormatted = draft.content.formattedText != nil
        self.isEmpty = draft.content.isEmpty
        self.sync = Self.badge(for: draft)
    }

    private static func badge(for draft: EntryDraft) -> SyncBadge {
        guard !draft.content.isEmpty else { return .hidden }
        let state = draft.syncStates.first { $0.target == .notion }
        if let state, state.status == .syncing { return .syncing }
        if let state, state.status == .failed { return .failed }
        // An entry edited since its last push counts as unsynced: that is the state most
        // worth flagging, because it's the one where the app and Notion silently disagree.
        if !draft.needsSync(to: .notion) { return .synced }
        return state?.externalId != nil ? .unsyncedChanges : .notSynced
    }
}
