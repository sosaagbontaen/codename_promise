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
    let preview: String
    let thumbnails: [Thumb]
    let hiddenThumbnailCount: Int
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
        self.preview = rawText == resolvedTitle ? "" : rawText
        self.thumbnails = media.prefix(thumbnailLimit).map {
            Thumb(id: $0.id, relativePath: $0.relativePath, isVideo: $0.kind == .video)
        }
        self.hiddenThumbnailCount = max(0, media.count - thumbnailLimit)
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
