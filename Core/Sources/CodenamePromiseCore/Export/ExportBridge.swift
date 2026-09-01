import Foundation

@MainActor
extension JournalExporter.Entry {

    /// Snapshots a draft for export.
    ///
    /// Note what comes along: media, and **any recording whose transcript has not been
    /// merged**. That second one is the point. A recording waiting in the queue holds words
    /// that exist nowhere else, so an export that quietly skipped it would lose precisely
    /// what the product promises to keep. `isSafeToDelete` is the app's own test for "these
    /// words are now durably in the entry" (ADR-002), so its inverse is exactly the set that
    /// still needs carrying out.
    public init(_ draft: EntryDraft) {
        let media = draft.orderedMedia.enumerated().map { index, item in
            JournalExporter.Entry.Attachment(
                // The original, never the compressed derivative: an export is the archive
                // copy, and the derivative exists only to satisfy an upload limit.
                relativePath: item.relativePath,
                suggestedName: Self.name(
                    prefix: item.kind == .video ? "video" : "photo",
                    index: index + 1,
                    path: item.relativePath
                )
            )
        }

        let pending = draft.orderedAudioCaptures
            .filter { !$0.isSafeToDelete }
            .enumerated()
            .map { index, capture in
                JournalExporter.Entry.Attachment(
                    relativePath: capture.relativePath,
                    suggestedName: Self.name(
                        prefix: "recording", index: index + 1, path: capture.relativePath
                    )
                )
            }

        self.init(
            id: draft.id,
            entryDateKey: draft.entryDateKey,
            title: draft.content.title,
            rawText: draft.content.rawText,
            formattedText: draft.content.formattedText,
            createdAt: draft.createdAt,
            updatedAt: draft.updatedAt,
            destinationURL: draft.syncStates
                .first { $0.target == .notion }
                .flatMap { DestinationLink.url(for: $0)?.web },
            media: media,
            pendingAudio: pending
        )
    }

    /// `photo-1.heic` &mdash; readable, ordered, and keeping whatever extension the bytes
    /// actually have so the file opens by double-clicking it.
    private static func name(prefix: String, index: Int, path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "\(prefix)-\(index)" : "\(prefix)-\(index).\(ext)"
    }
}

@MainActor
extension DraftStore {
    /// Exports the whole journal to a directory, newest day first.
    @discardableResult
    public func exportAll(
        to directory: URL,
        fileStore: MediaFileStore
    ) throws -> JournalExporter.Summary {
        let entries = try allDrafts().map(JournalExporter.Entry.init)
        return try JournalExporter(fileStore: fileStore).write(entries, to: directory)
    }
}
