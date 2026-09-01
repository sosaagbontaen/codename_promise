import Foundation
import SwiftData

/// The only thing that mutates persisted state.
///
/// **Why `@MainActor`.** `@Model` types are reference types and are not `Sendable`;
/// `ModelContext` is not thread-safe. The tempting shape — a service holding an
/// `EntryDraft`, awaiting the network, then mutating it on whatever thread resumes — is a
/// data race that reproduces only on slow connections. Pinning all model mutation to the
/// main actor makes that shape fail to compile under Swift 6 rather than fail in the
/// field. Journal-sized data does not need a background context. See ADR-009a.
///
/// **Why saves are explicit.** SwiftData's autosave is not a per-mutation durability
/// guarantee; it saves at opportune moments, chiefly around scene-phase changes. During an
/// eight-minute foreground dictation no such moment arrives, so a jetsam takes everything
/// since the last opportunistic save — precisely the bug this project exists to kill. Every
/// mutating method here commits, and `flush()` is called again on scene-phase change. See
/// ADR-001.
@MainActor
public final class DraftStore {
    public let context: ModelContext
    private let clock: () -> Date

    /// How long an in-flight operation may claim to be running before it's treated as
    /// abandoned by a dead process. See ADR-004.
    public var staleOperationTimeout: TimeInterval = 5 * 60

    public init(container: ModelContainer, clock: @escaping () -> Date = { Date() }) {
        self.context = ModelContext(container)
        // Belt and braces: we save explicitly, and autosave stays on as a backstop for
        // anything that mutates a model without going through this class.
        self.context.autosaveEnabled = true
        self.clock = clock
    }

    // MARK: - Durability

    /// Commits pending changes. Throws so callers can surface a real failure instead of
    /// silently believing work is safe.
    public func flush() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    /// Call from `.onChange(of: scenePhase)` for `.inactive` and `.background`.
    /// Swallows errors by design — this runs during teardown where there is nobody to tell,
    /// and a best-effort save beats a crash on the way out.
    public func flushQuietly() {
        try? flush()
    }

    // MARK: - Drafts

    @discardableResult
    public func createDraft(entryDate: CalendarDay? = nil, timeZone: TimeZone = .current) throws -> EntryDraft {
        let draft = EntryDraft(createdAt: clock(), entryDate: entryDate, timeZone: timeZone)
        context.insert(draft)
        try flush()
        return draft
    }

    public func draft(id: UUID) throws -> EntryDraft? {
        // Note: fetched by an explicit predicate on a UUID attribute rather than by
        // PersistentIdentifier, so callers can hold a plain UUID across an await boundary
        // without holding a non-Sendable model. See ADR-009a.
        var descriptor = FetchDescriptor<EntryDraft>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public func allDrafts() throws -> [EntryDraft] {
        // entryDateKey is `yyyy-MM-dd`, so string ordering is chronological ordering.
        try context.fetch(
            FetchDescriptor<EntryDraft>(sortBy: [
                SortDescriptor(\.entryDateKey, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
            ])
        )
    }

    public func drafts(on day: CalendarDay) throws -> [EntryDraft] {
        let key = day.rawValue
        return try context.fetch(
            FetchDescriptor<EntryDraft>(
                predicate: #Predicate { $0.entryDateKey == key },
                sortBy: [SortDescriptor(\.createdAt)]
            )
        )
    }

    /// The days in a window that already have at least one entry.
    ///
    /// `entryDateKey` is `yyyy-MM-dd`, so a lexicographic range is a chronological range and
    /// this needs no date arithmetic in the predicate (ADR-006).
    public func entryDays(from: CalendarDay, through: CalendarDay) throws -> Set<CalendarDay> {
        let lower = from.rawValue
        let upper = through.rawValue
        let drafts = try context.fetch(
            FetchDescriptor<EntryDraft>(
                predicate: #Predicate { $0.entryDateKey >= lower && $0.entryDateKey <= upper }
            )
        )
        return Set(drafts.compactMap { CalendarDay(rawValue: $0.entryDateKey) })
    }

    /// Every entry in a window, reduced to what "is this finished?" needs.
    ///
    /// Returns values rather than models on purpose: the caller is deciding what to show, not
    /// what to edit, and a `Sendable` row can cross an actor boundary while an `EntryDraft`
    /// cannot (ADR-009a). Callers that then want to *open* one re-fetch by `id`.
    ///
    /// A recording counts as words even before it is transcribed. Anything else would have
    /// the app tell someone the three minutes they just dictated is an entry with nothing in
    /// it, which is the exact fear this product exists to answer (ADR-002).
    public func entryCompleteness(
        from: CalendarDay, through: CalendarDay
    ) throws -> [LocalEntryRow] {
        let lower = from.rawValue
        let upper = through.rawValue
        let drafts = try context.fetch(
            FetchDescriptor<EntryDraft>(
                predicate: #Predicate { $0.entryDateKey >= lower && $0.entryDateKey <= upper }
            )
        )
        return drafts.compactMap { draft in
            guard let day = CalendarDay(rawValue: draft.entryDateKey) else { return nil }
            let dictated = !draft.orderedAudioCaptures.isEmpty
            let typed = !draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return LocalEntryRow(
                id: draft.id,
                day: day,
                title: draft.content.title,
                hasWords: typed || dictated,
                hasMedia: !draft.orderedMedia.isEmpty,
                linkedPageId: draft.syncStates.first { $0.target == .notion }?.externalId
            )
        }
    }

    /// Points a draft at an entry that already exists in the destination.
    ///
    /// So that finishing a half-written Notion page adds to *that* page instead of making a
    /// second entry for the same day - which is what the app would otherwise do, and what
    /// would make the unfinished-entries list actively harmful to use.
    public func attachToExistingPage(
        _ pageId: String, title: String?, for draft: EntryDraft
    ) throws {
        draft.syncState(for: .notion).attachToExistingPage(pageId, title: title)
        try flush()
    }

    /// The earliest day the user has ever written about, or nil if they never have.
    ///
    /// Bounds the open-days window so a new install is never shown a backlog it did not earn.
    /// See `JournalGaps`.
    public func earliestEntryDay() throws -> CalendarDay? {
        var descriptor = FetchDescriptor<EntryDraft>(
            sortBy: [SortDescriptor(\.entryDateKey, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first.flatMap { CalendarDay(rawValue: $0.entryDateKey) }
    }

    /// Deletes a draft and the bytes it owned. Cascade rules clear the rows; the file store
    /// has to be told about the files. See ADR-018a.
    public func delete(_ draft: EntryDraft, fileStore: MediaFileStore?) throws {
        let paths = draft.media.flatMap(\.ownedRelativePaths)
            + draft.audioCaptures.flatMap(\.ownedRelativePaths)
        context.delete(draft)
        try flush()
        fileStore?.delete(relativePaths: paths)
    }

    // MARK: - Capture

    /// Persists typed text. Callers debounce keystrokes (~300ms) and additionally flush on
    /// scene-phase change; this method itself always commits.
    public func updateRawText(_ text: String, for draft: EntryDraft) throws {
        draft.updateRawText(text, now: clock())
        try flush()
    }

    public func updateTitle(_ title: String?, for draft: EntryDraft) throws {
        draft.updateTitle(title, now: clock())
        try flush()
    }

    public func setEntryDate(_ day: CalendarDay, for draft: EntryDraft) throws {
        draft.setEntryDate(day, now: clock())
        try flush()
    }

    /// The user editing the structured text by hand.
    public func updateFormattedText(_ text: String, for draft: EntryDraft) throws {
        draft.updateFormattedText(text, now: clock())
        try flush()
    }

    /// Writes the AI's structural pass. There is no path from here to `rawText`.
    public func applyFormatting(
        _ formatted: String,
        formatterVersion: String,
        to draft: EntryDraft
    ) throws {
        draft.applyFormatting(formatted, formatterVersion: formatterVersion, now: clock())
        try flush()
    }

    // MARK: - Media

    /// Adopts the file into the store *then* records it, and commits before returning.
    /// The ordering matters: bytes first, row second, so the worst case is an orphan file
    /// rather than a row pointing at nothing.
    @discardableResult
    public func attachMedia(
        from sourceURL: URL,
        kind: MediaKind,
        to draft: EntryDraft,
        fileStore: MediaFileStore
    ) throws -> MediaItem {
        let adopted = try fileStore.adopt(fileAt: sourceURL)
        let item = MediaItem(
            id: adopted.id,
            kind: kind,
            relativePath: adopted.relativePath,
            originalSizeBytes: adopted.sizeBytes,
            createdAt: clock()
        )
        context.insert(item)
        draft.attach(item, now: clock())
        try flush()
        return item
    }

    /// Copies an entry into a new one.
    ///
    /// Three things are deliberate about what does and doesn't come along:
    ///
    /// - **Media bytes are duplicated, not shared.** Two rows pointing at one file would mean
    ///   deleting either entry destroys the other's photo, because deletion removes the bytes
    ///   (ADR-018a). Each copy owns its own.
    /// - **Sync state is not copied.** The clone is a new entry that exists nowhere yet;
    ///   inheriting a page id would make it overwrite the original's page on the next sync.
    /// - **Dictation audio is not copied.** It's scaffolding awaiting transcription (ADR-002),
    ///   and duplicating it would transcribe the same recording twice. The transcript itself
    ///   already lives in `rawText`, so nothing the user said is lost.
    @discardableResult
    public func duplicate(_ draft: EntryDraft, fileStore: MediaFileStore?) throws -> EntryDraft {
        let copy = EntryDraft(createdAt: clock(), entryDate: draft.entryDate)
        context.insert(copy)

        // Through the model's own mutators so `updatedAt` stays honest (invariant 2).
        copy.updateTitle(draft.content.title, now: clock())
        copy.updateRawText(draft.content.rawText, now: clock())
        if let formatted = draft.content.formattedText {
            copy.applyFormatting(
                formatted,
                formatterVersion: draft.content.formatterVersion ?? "unknown",
                now: clock()
            )
        }

        if let fileStore {
            for item in draft.orderedMedia {
                guard fileStore.exists(item.relativePath),
                      let adopted = try? fileStore.adopt(
                        fileAt: fileStore.url(for: item.relativePath)
                      )
                else { continue }

                let duplicated = MediaItem(
                    id: adopted.id,
                    kind: item.kind,
                    relativePath: adopted.relativePath,
                    originalSizeBytes: adopted.sizeBytes,
                    createdAt: clock()
                )
                context.insert(duplicated)
                copy.attach(duplicated, now: clock())
            }
        }

        try flush()
        return copy
    }

    /// Moves attachments from one entry to another.
    ///
    /// Filing photos under the wrong day is easy to do — especially importing a week of them
    /// at once — and the only fix used to be deleting each one and picking it again from the
    /// library. That is worse than tedious: `removeMedia` deletes the bytes (ADR-018a), so
    /// the repair is a real data-loss window if the user doesn't finish it.
    ///
    /// Nothing is copied and nothing is deleted. `relativePath` is keyed by the item, not by
    /// the entry that happens to own it (ADR-007), so a move is purely re-parenting the row —
    /// which also means it cannot fail halfway and lose a photo.
    ///
    /// Both entries are marked as changed, so each re-syncs to its own destination.
    @discardableResult
    public func moveMedia(
        ids: Set<UUID>,
        from source: EntryDraft,
        to destination: EntryDraft
    ) throws -> Int {
        guard source.id != destination.id, !ids.isEmpty else { return 0 }

        // Ordered so the arrival order matches what the user saw when they selected.
        let moving = source.orderedMedia.filter { ids.contains($0.id) }
        guard !moving.isEmpty else { return 0 }

        let now = clock()
        for item in moving {
            guard let detached = source.detachMedia(id: item.id, now: now) else { continue }
            destination.attach(detached, now: now)
        }
        try flush()
        return moving.count
    }

    public func removeMedia(id: UUID, from draft: EntryDraft, fileStore: MediaFileStore?) throws {
        guard let removed = draft.detachMedia(id: id, now: clock()) else { return }
        let paths = removed.ownedRelativePaths
        context.delete(removed)
        try flush()
        fileStore?.delete(relativePaths: paths)
    }

    // MARK: - Dictation

    /// Records a finished audio chunk. The data is on disk and the row is committed before
    /// this returns, so transcription is free to fail forever without costing the user
    /// anything but convenience. See ADR-002.
    @discardableResult
    public func attachAudioCapture(
        data: Data,
        fileExtension: String,
        durationSeconds: Double,
        to draft: EntryDraft,
        fileStore: MediaFileStore
    ) throws -> AudioCapture {
        let written = try fileStore.write(data, preferredName: "dictation", extension: fileExtension)
        let capture = AudioCapture(
            id: written.id,
            relativePath: written.relativePath,
            durationSeconds: durationSeconds,
            sizeBytes: written.sizeBytes,
            recordedAt: clock()
        )
        context.insert(capture)
        draft.attach(capture, now: clock())
        try flush()
        return capture
    }

    /// Merges a transcript into the draft and only then marks the audio releasable.
    /// Both writes land in one commit, so there is no window where the audio looks
    /// disposable but its words aren't saved.
    /// Merges a transcript into the draft. Returns false when there was nothing to merge.
    ///
    /// An empty transcript must NOT be treated as success. It used to be: `appendRawText`
    /// guards against blank text and returns early, but `mergedIntoDraftAt` was set anyway —
    /// so a recording that captured silence was marked complete, the "waiting to transcribe"
    /// notice vanished, no words appeared, and nothing was reported. Silent success is the
    /// worst possible outcome for an app whose promise is that nothing is lost.
    ///
    /// The audio is kept and the capture stays incomplete, so the user can retry or at least
    /// see that the recording is still there.
    @discardableResult
    public func mergeTranscript(
        _ text: String,
        from capture: AudioCapture,
        into draft: EntryDraft
    ) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let now = clock()
        capture.markTranscribed(trimmed)
        draft.appendRawText(trimmed, now: now)
        capture.mergedIntoDraftAt = now
        try flush()
        return true
    }

    /// Captures whose transcript is safely committed to a draft, so their bytes *could* be
    /// reclaimed. Distinct from `pendingTranscriptions()`, which by definition excludes
    /// anything already transcribed.
    public func releasableAudioCaptures() throws -> [AudioCapture] {
        let transcribed = TranscriptionStatus.transcribed.rawValue
        return try context.fetch(
            FetchDescriptor<AudioCapture>(
                predicate: #Predicate { $0.transcriptionStatusRaw == transcribed }
            )
        ).filter(\.isSafeToDelete)
    }

    public func audioCapture(id: UUID) throws -> AudioCapture? {
        var descriptor = FetchDescriptor<AudioCapture>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Pending transcriptions whose backoff has elapsed, oldest first.
    ///
    /// The backoff filter runs in memory rather than in the predicate: the candidate set is
    /// tiny, and predicates over optional dates are a needless place to be clever.
    public func dueTranscriptions(now: Date = Date()) throws -> [AudioCapture] {
        try pendingTranscriptions().filter { $0.isTranscriptionDue(now: now) }
    }

    public func pendingTranscriptions() throws -> [AudioCapture] {
        let pending = TranscriptionStatus.pending.rawValue
        let failed = TranscriptionStatus.failed.rawValue
        // Predicate over the raw string, per ADR-012.
        var descriptor = FetchDescriptor<AudioCapture>(
            predicate: #Predicate { capture in
                capture.transcriptionStatusRaw == pending || capture.transcriptionStatusRaw == failed
            },
            sortBy: [SortDescriptor(\.recordedAt), SortDescriptor(\.chunkIndex)]
        )
        descriptor.fetchLimit = 100
        return try context.fetch(descriptor)
    }

    // MARK: - Recovery

    /// Demotes operations abandoned by a dead process back to a retryable state.
    ///
    /// Call once at launch, before any UI reads state. Without this, a kill mid-sync leaves
    /// `status == .syncing` — which means "don't retry" — forever, and the draft can never
    /// be synced again. See ADR-004.
    @discardableResult
    public func reconcileAbandonedOperations() throws -> ReconciliationReport {
        let now = clock()
        var report = ReconciliationReport()

        let syncing = SyncStatus.syncing.rawValue
        for state in try context.fetch(
            FetchDescriptor<SyncState>(predicate: #Predicate { $0.statusRaw == syncing })
        ) where state.isStale(now: now, timeout: staleOperationTimeout) {
            state.markFailed("Interrupted — the app closed before this sync finished.")
            report.recoveredSyncStates += 1
        }

        let uploading = UploadStatus.uploading.rawValue
        for item in try context.fetch(
            FetchDescriptor<MediaItem>(predicate: #Predicate { $0.uploadStatusRaw == uploading })
        ) where item.isUploadStale(now: now, timeout: staleOperationTimeout) {
            item.markUploadFailed("Interrupted — the app closed before this upload finished.")
            report.recoveredUploads += 1
        }

        let transcribing = TranscriptionStatus.transcribing.rawValue
        for capture in try context.fetch(
            FetchDescriptor<AudioCapture>(predicate: #Predicate { $0.transcriptionStatusRaw == transcribing })
        ) where capture.isTranscriptionStale(now: now, timeout: staleOperationTimeout) {
            // Back to .pending rather than .failed: the audio is still on disk, so this is
            // simply work not yet done, and presenting it as a failure would be a lie.
            capture.transcriptionStatus = .pending
            capture.transcriptionStartedAt = nil
            report.recoveredTranscriptions += 1
        }

        try flush()
        return report
    }

    /// Every relative path currently claimed by a record — the input to orphan reaping.
    public func claimedRelativePaths() throws -> Set<String> {
        var claimed = Set<String>()
        for item in try context.fetch(FetchDescriptor<MediaItem>()) {
            claimed.formUnion(item.ownedRelativePaths)
        }
        for capture in try context.fetch(FetchDescriptor<AudioCapture>()) {
            claimed.formUnion(capture.ownedRelativePaths)
        }
        return claimed
    }
}

public struct ReconciliationReport: Sendable, Hashable {
    public var recoveredSyncStates = 0
    public var recoveredUploads = 0
    public var recoveredTranscriptions = 0

    public var isEmpty: Bool {
        recoveredSyncStates == 0 && recoveredUploads == 0 && recoveredTranscriptions == 0
    }
}
