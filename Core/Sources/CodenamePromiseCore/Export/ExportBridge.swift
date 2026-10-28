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
        /// The entries this import brought in or finished, newest day first, so the screen
        /// can show what arrived rather than only how many.
        public var importedIds: [UUID] = []
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
        fileStore: MediaFileStore,
        progress: (JournalImportProgress) -> Void = { _ in }
    ) async throws -> ImportReport {
        // A folder in iCloud Drive is often mostly not on the phone yet. Everything is asked
        // for at once, so photos download while the entries are still being read, instead of
        // each file waiting its turn.
        Task.detached(priority: .utility) { JournalImporter.startDownloading(directory) }

        // Reading the entries can mean downloading each one, so it happens off the main actor,
        // several at a time, with the count shown as it goes. Without this the bar sat empty
        // for the minute or more a year of entries took to arrive.
        let names = try await Task.detached { try JournalImporter().entryFileNames(in: directory) }.value
        var state = JournalImportProgress(readTotal: names.count)
        progress(state)
        var reading = JournalImporter.Reading()
        for start in stride(from: 0, to: names.count, by: 8) {
            let batch = Array(names[start..<min(start + 8, names.count)])
            for (name, entry) in zip(batch, await JournalImporter.readEntries(named: batch, in: directory)) {
                if let entry { reading.entries.append(entry) } else { reading.unreadable.append(name) }
            }
            state.readDone += batch.count
            progress(state)
        }
        reading.entries.sort { $0.entryDateKey > $1.entryDateKey }
        var report = ImportReport(unreadable: reading.unreadable)

        // Trashed entries count too, or importing would bring back a second copy of one.
        let existing = Set(try allDraftsIncludingTrashed().map(\.id))
        // Entries an interrupted import had started. They exist, so the skip below would
        // leave them without the photos the interruption cut off; they're finished instead.
        let defaults = importBookkeeping
        var unfinished = Set(defaults.stringArray(forKey: Self.unfinishedImportKey) ?? [])
        func remember() { defaults.set(Array(unfinished), forKey: Self.unfinishedImportKey) }

        state.entriesTotal = reading.entries.count
        state.filesTotal = reading.entries.reduce(0) { $0 + $1.attachments.count + $1.untranscribedAudio.count }
        progress(state)

        for parsed in reading.entries {
            let files = parsed.attachments + parsed.untranscribedAudio
            // Files already counted for this entry as they were copied; the rest (already
            // here, or skipped with the entry) are counted when it's done.
            var counted = 0
            defer {
                state.entriesDone += 1
                state.filesDone += files.count - counted
                progress(state)
            }

            let draft: EntryDraft
            if let id = parsed.id, existing.contains(id) {
                guard unfinished.contains(id.uuidString), let resumed = try self.draft(id: id) else {
                    report.alreadyPresent += 1
                    continue
                }
                draft = resumed
            } else {
                guard let day = CalendarDay(rawValue: parsed.entryDateKey) else {
                    report.unreadable.append(parsed.entryDateKey)
                    continue
                }
                // Keeps the id the export recorded. Without it an imported entry gets a fresh
                // UUID, the folder's ids never match anything in the store, and the skip above
                // can never fire - so a second run of the same import silently doubles the
                // journal. That is the failure that would make this feature worse than not
                // having it, and it is what `importIsIdempotent` exists to catch.
                let id = parsed.id ?? UUID()
                unfinished.insert(id.uuidString)
                remember()
                draft = try createDraft(id: id, entryDate: day)
                if let title = parsed.title { try updateTitle(title, for: draft) }
                try updateRawText(parsed.rawText, for: draft)
                report.added += 1
            }

            // Each attachment's id comes from the entry and its path, so a resumed import
            // recognises what it already brought in and doesn't attach it twice.
            let have = Set(draft.media.map(\.id))
            let wanted = files
                .map { (relative: $0, id: InboxScanner.stableUUID("\(draft.id.uuidString)|\($0)")) }
                .filter { !have.contains($0.id) }
            let copied = await adopt(wanted, from: directory, into: fileStore) {
                counted += 1
                state.filesDone += 1
                progress(state)
            }
            for (relative, adopted) in copied {
                guard let adopted else {
                    report.missingAttachments.append(relative)
                    continue
                }
                let kind = MediaKind.forExtension((relative as NSString).pathExtension)
                try record(adopted, kind: kind, to: draft)
                report.attachments += 1
            }

            unfinished.remove(draft.id.uuidString)
            remember()
            report.importedIds.append(draft.id)
            // Lets the screen draw between entries on a long import.
            await Task.yield()
        }

        try flush()
        return report
    }

    static let unfinishedImportKey = "journalImport.unfinishedEntries"

    /// Copies files into the store a few at a time, off the main actor, in the order given.
    /// Nil for a file that isn't there or couldn't be read.
    ///
    /// Each read is coordinated, which is what makes iCloud Drive download a file that's only
    /// in the cloud before handing it over. A plain copy can find nothing there, and an
    /// attachment that was only waiting to download would be reported as missing.
    private func adopt(
        _ wanted: [(relative: String, id: UUID)],
        from directory: URL,
        into fileStore: MediaFileStore,
        each: () -> Void
    ) async -> [(String, AdoptedFile?)] {
        guard !wanted.isEmpty else { return [] }
        let results = await withTaskGroup(of: (Int, AdoptedFile?).self) { group -> [AdoptedFile?] in
            var results = [AdoptedFile?](repeating: nil, count: wanted.count)
            var next = 0
            func start() {
                guard next < wanted.count else { return }
                let index = next
                next += 1
                let source = directory.appendingPathComponent(wanted[index].relative)
                let id = wanted[index].id
                group.addTask { (index, Self.coordinatedAdopt(source, id: id, into: fileStore)) }
            }
            for _ in 0..<4 { start() }
            while let (index, adopted) = await group.next() {
                results[index] = adopted
                each()
                start()
            }
            return results
        }
        return zip(wanted, results).map { ($0.relative, $1) }
    }

    nonisolated private static func coordinatedAdopt(_ source: URL, id: UUID, into fileStore: MediaFileStore) -> AdoptedFile? {
        var adopted: AdoptedFile?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges], error: &error) { url in
            adopted = try? fileStore.adopt(fileAt: url, id: id)
        }
        return adopted
    }
}

/// How far a journal import has got, for a progress bar.
public struct JournalImportProgress: Sendable, Equatable {
    /// Entry files read from the folder so far, which for iCloud Drive means downloaded.
    public var readDone = 0
    public var readTotal = 0
    public var entriesDone = 0
    public var entriesTotal = 0
    public var filesDone = 0
    public var filesTotal = 0

    public init(readDone: Int = 0, readTotal: Int = 0, entriesDone: Int = 0, entriesTotal: Int = 0,
                filesDone: Int = 0, filesTotal: Int = 0) {
        self.readDone = readDone
        self.readTotal = readTotal
        self.entriesDone = entriesDone
        self.entriesTotal = entriesTotal
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }

    /// Whether it's still reading the folder's entries in.
    public var isReading: Bool { entriesTotal == 0 && readDone < readTotal }

    /// The first tenth of the bar is reading the entries; the rest is bringing them in, with
    /// entries and files together, so a year of text alone still moves it.
    public var fraction: Double {
        let reading = readTotal == 0 ? 0 : Double(readDone) / Double(readTotal)
        let total = entriesTotal + filesTotal
        let adding = total == 0 ? 0 : Double(entriesDone + filesDone) / Double(total)
        return 0.1 * reading + 0.9 * adding
    }
}
