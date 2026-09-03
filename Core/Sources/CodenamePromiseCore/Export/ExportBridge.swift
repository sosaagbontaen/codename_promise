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

    /// The same export, narrowed to entries the user picked.
    ///
    /// Export was all-or-nothing, which is right for a backup and wrong for the other half of
    /// what people do with it: sending one trip, or one month, to somebody. The writer always
    /// took an array; only the store insisted on handing it everything.
    ///
    /// Order follows the ids given, so a selection exports in the order it was made.
    public func export(
        ids: [UUID],
        to directory: URL,
        fileStore: MediaFileStore
    ) throws -> JournalExporter.Summary {
        var entries: [JournalExporter.Entry] = []
        for id in ids {
            if let draft = try draft(id: id) {
                entries.append(JournalExporter.Entry(draft))
            }
        }
        return try JournalExporter(fileStore: fileStore).write(entries, to: directory)
    }

    /// What an import did, in the terms the person cares about.
    public struct ImportReport: Sendable, Equatable {
        public var added = 0
        /// Entries whose id was already here. Skipped, not merged, not duplicated.
        public var alreadyPresent = 0
        public var attachments = 0
        /// Files an entry named that were not in the folder. Reported, never fatal.
        public var missingAttachments: [String] = []
        /// Markdown files that could not be read at all.
        public var unreadable: [String] = []

        public var isCompleteRecord: Bool {
            missingAttachments.isEmpty && unreadable.isEmpty
        }
    }

    /// Brings a previously exported folder back in.
    ///
    /// **Additive and never destructive.** Nothing already on this device is modified or
    /// deleted, and an entry whose id is already present is skipped - so importing the same
    /// folder twice leaves one copy, not two, and importing a folder that overlaps what you
    /// have merges cleanly instead of doubling it.
    ///
    /// **The words come in even when the pictures do not.** A named attachment missing from
    /// the folder is recorded and skipped; the entry still arrives with its text. Losing a
    /// photo is a shame, losing the writing because of a photo is the failure this product
    /// exists to prevent.
    ///
    /// Bytes are adopted into the container before any row references them, so an import
    /// that is interrupted leaves no entry pointing at a file outside the app (ADR-007).
    public func importJournal(
        from directory: URL,
        fileStore: MediaFileStore
    ) throws -> ImportReport {
        let reading = try JournalImporter().read(directory: directory)
        var report = ImportReport(unreadable: reading.unreadable)

        let existing = Set(try allDrafts().map(\.id))

        for parsed in reading.entries {
            if let id = parsed.id, existing.contains(id) {
                report.alreadyPresent += 1
                continue
            }
            guard let day = CalendarDay(rawValue: parsed.entryDateKey) else {
                report.unreadable.append(parsed.entryDateKey)
                continue
            }

            // Keeps the id the export recorded. Without it an imported entry gets a fresh
            // UUID, the folder's ids never match anything in the store, and the skip above
            // can never fire - so a second run of the same import silently doubles the
            // journal. That is the failure that would make this feature worse than not
            // having it, and it is what `importIsIdempotent` exists to catch.
            let draft = try createDraft(id: parsed.id ?? UUID(), entryDate: day)
            if let title = parsed.title { try updateTitle(title, for: draft) }
            try updateRawText(parsed.rawText, for: draft)

            for relative in parsed.attachments + parsed.untranscribedAudio {
                let source = directory.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    report.missingAttachments.append(relative)
                    continue
                }
                let kind = MediaKind.forExtension(source.pathExtension)
                _ = try attachMedia(from: source, kind: kind, to: draft, fileStore: fileStore)
                report.attachments += 1
            }

            report.added += 1
        }

        try flush()
        return report
    }
}
