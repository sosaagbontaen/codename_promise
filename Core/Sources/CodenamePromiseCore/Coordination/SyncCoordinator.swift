import Foundation
import Observation

/// Drives the multi-step push to a destination.
///
/// Three properties this must have, each of which corresponds to a way the original workflow
/// failed:
///
///  1. **Resumable.** A failure at step three does not restart from step one. Restarting is
///     what duplicates content in the destination. (ADR-005)
///  2. **Idempotent.** Every mutating call carries a key that is stable across retries of the
///     same content, so a step whose response was lost replays instead of writing twice.
///     (ADR-003)
///  3. **Media failure is not entry failure.** "Upload failures causing the entire entry to
///     fail" is on the founding list of problems. A photo that won't upload must not stop the
///     words getting where they're going.
@MainActor
@Observable
public final class SyncCoordinator {
    public private(set) var inFlight: Set<UUID> = []
    public private(set) var lastError: String?

    /// Real progress for each in-flight draft, derived from the phases actually completed
    /// rather than from a timer. A sync that stalls on a slow upload shows a bar that has
    /// genuinely stopped, which is more informative than a spinner that keeps turning.
    public private(set) var progress: [UUID: SyncProgress] = [:]

    public func progress(for draftId: UUID) -> SyncProgress? { progress[draftId] }

    private let store: DraftStore
    private let fileStore: MediaFileStore
    private let notion: any NotionAPI
    private let connection: (any NotionConnectionService)?
    private let clock: () -> Date

    public init(
        store: DraftStore,
        fileStore: MediaFileStore,
        notion: any NotionAPI,
        connection: (any NotionConnectionService)? = nil,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.fileStore = fileStore
        self.notion = notion
        self.connection = connection
        self.clock = clock
    }

    public func isSyncing(_ draftId: UUID) -> Bool { inFlight.contains(draftId) }

    // MARK: - Entry points

    /// Pushes one draft to one destination.
    @discardableResult
    public func sync(draftId: UUID, to target: SyncTarget = .notion) async -> SyncOutcome {
        guard !inFlight.contains(draftId) else { return .alreadyRunning }
        inFlight.insert(draftId)
        defer { inFlight.remove(draftId) }

        defer { progress[draftId] = nil }
        report(draftId, .preparing)

        guard let draft = try? store.draft(id: draftId) else { return .vanished }
        guard !draft.content.isEmpty else { return .nothingToSync }

        let state = draft.syncState(for: target)

        // Which Notion are we talking to? Cached page, file and block IDs are only valid
        // against the destination that issued them, so a change of workspace, database — or
        // a switch from a development stub to the real thing — must discard them rather than
        // send fabricated references. See `SyncState.adoptDestination`.
        if let connection, let status = try? await connection.status() {
            if state.adoptDestination(status.destinationFingerprint) {
                try? store.flush()
                lastError = nil
            }
        }

        // Snapshot everything the destination will receive, *before* any await. The user may
        // keep typing while this runs; the attempt must send the content its idempotency key
        // was minted for, not whatever the model looks like when a response lands. (ADR-016)
        let snapshot = ContentSnapshot(
            contentHash: draft.contentHash,
            title: draft.content.title,
            entryDate: draft.entryDate,
            // The arranged entry when there is one, because that is the thing this app
            // makes. Sending the raw transcript instead meant a destination received the
            // ramble — "okay so today, um, where was I" — while the app itself showed the
            // organised version, which is the opposite of the promise.
            //
            // Falls back to structured text for entries written before arranging existed,
            // then to the person's own words. An entry that has never been arranged is still
            // a complete entry.
            body: EntryMarkdown.body(
                organised: draft.organised,
                formatted: draft.content.formattedText,
                raw: draft.content.rawText
            )
        )

        state.beginAttempt(contentHash: snapshot.contentHash, now: clock())
        // Commit the lease before the first call, so a process death here is visible to launch
        // reconciliation rather than silently stranding the draft. (ADR-004)
        try? store.flush()

        do {
            report(draftId, state.appendsToExistingPage ? .findingPage : .creatingPage)
            let pageId = try await ensurePage(draft: draft, state: state, snapshot: snapshot)

            // Words first, on their own.
            //
            // Media used to go first and travel with the text in one call, which meant a
            // failure anywhere in a five-photo upload left a page that had been created and
            // left empty, with the entry still only on the phone. Uploading is the slow part
            // and the part most likely to fail, so it is the part that must not be standing
            // in front of the words.
            report(draftId, .writingText)
            try await insertText(state: state, snapshot: snapshot, pageId: pageId)

            let photos = draft.orderedMedia.filter { $0.kind == .photo }
            let videos = draft.orderedMedia.filter { $0.kind == .video }

            if !photos.isEmpty || !state.photoBlockIds.isEmpty {
                let uploaded = await uploadPendingMedia(photos, state: state) { done, total in
                    self.report(draftId, .uploadingPhotos(done: done, total: total))
                }
                report(draftId, .attachingPhotos)
                try await attach(
                    uploaded, state: state, pageId: pageId,
                    replacing: state.photoBlockIds, step: "insert-photos",
                    reached: .photosAttached
                ) { state.photoBlockIds = $0 }
            } else {
                state.advance(to: .photosAttached)
            }

            // Videos last because they are the biggest and slowest. By the time one is still
            // climbing, the entry and every photo are already on the page.
            if !videos.isEmpty || !state.videoBlockIds.isEmpty {
                let uploaded = await uploadPendingMedia(videos, state: state) { done, total in
                    self.report(draftId, .uploadingVideos(done: done, total: total))
                }
                report(draftId, .attachingVideos)
                try await attach(
                    uploaded, state: state, pageId: pageId,
                    replacing: state.videoBlockIds, step: "insert-videos",
                    reached: .videosAttached
                ) { state.videoBlockIds = $0 }
            } else {
                state.advance(to: .videosAttached)
            }

            // Never rewrite the title or date of a page the user already had. On their entry
            // that is not housekeeping, it is overwriting something they wrote.
            if !state.appendsToExistingPage {
                report(draftId, .updatingProperties)
                try await updateProperties(state: state, snapshot: snapshot, pageId: pageId)
            } else {
                state.advance(to: .propertiesUpdated)
            }
            report(draftId, .finishing)

            guard let draft = try? store.draft(id: draftId) else { return .vanished }
            let stillCurrent = draft.contentHash == snapshot.contentHash
            state.markSynced(externalId: pageId, contentHash: snapshot.contentHash, now: clock())
            try store.flush()
            lastError = nil

            // If the user edited while this was in flight, the destination now holds the older
            // version — correctly reported as dirty rather than quietly wrong.
            return stillCurrent ? .synced : .syncedButSupersededByEdits
        } catch let error as APIError {
            state.markFailed(error.userFacingMessage)
            try? store.flush()
            lastError = error.userFacingMessage
            return error.isRetryable ? .deferred(error.userFacingMessage) : .failed(error.userFacingMessage)
        } catch {
            state.markFailed(error.localizedDescription)
            try? store.flush()
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Pushes every draft whose content has changed since its last successful sync.
    @discardableResult
    public func syncAllDirty(to target: SyncTarget = .notion) async -> SyncRunSummary {
        var summary = SyncRunSummary()
        let candidates: [UUID]
        do {
            candidates = try store.allDrafts()
                .filter { $0.needsSync(to: target) && !$0.content.isEmpty }
                .map(\.id)
        } catch {
            lastError = error.localizedDescription
            return summary
        }

        for draftId in candidates {
            switch await sync(draftId: draftId, to: target) {
            case .synced, .syncedButSupersededByEdits:
                summary.synced += 1
            case .deferred(let reason):
                summary.deferred += 1
                // The rest will fail the same way — stop rather than marking every draft
                // failed in turn.
                summary.stoppedEarlyBecause = reason
                return summary
            case .failed:
                summary.failed += 1
            case .nothingToSync, .vanished, .alreadyRunning:
                summary.skipped += 1
            }
        }
        return summary
    }

    // MARK: - Steps

    private func ensurePage(
        draft: EntryDraft,
        state: SyncState,
        snapshot: ContentSnapshot
    ) async throws -> String {
        if state.phase.rank >= SyncPhase.pageEnsured.rank, let existing = state.externalId {
            return existing
        }
        let pageId = try await notion.ensurePage(
            EnsurePageRequest(
                draftId: draft.id,
                entryDate: snapshot.entryDate,
                title: snapshot.title,
                existingExternalId: state.externalId,
                idempotencyKey: key(state, step: "ensure-page")
            )
        )
        state.externalId = pageId
        state.advance(to: .pageEnsured)
        try? store.flush()
        return pageId
    }

    private func report(_ draftId: UUID, _ step: SyncProgress) {
        progress[draftId] = step
    }

    /// Uploads media that hasn't already been uploaded during this attempt.
    ///
    /// Deliberately non-throwing. A failed upload marks that item and moves on — the entry
    /// still syncs with whatever media did make it. Losing a photo is annoying; losing the
    /// reflection because of a photo is the bug this project exists to fix.
    private func uploadPendingMedia(
        _ items: [MediaItem],
        state: SyncState,
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async -> [AttachedFile] {
        var fileIds: [AttachedFile] = []
        let total = items.count
        var done = 0
        if total > 0 { onProgress(0, total) }

        for item in items {
            defer { done += 1; if total > 0 { onProgress(done, total) } }
            if let existing = state.uploadedFileId(for: item.id) {
                fileIds.append(AttachedFile(id: existing, kind: item.kind))
                continue
            }

            let path = item.pathForUpload
            guard fileStore.exists(path) else {
                item.markUploadFailed("The file is missing.")
                try? store.flush()
                continue
            }

            item.markUploading(now: clock())
            try? store.flush()

            do {
                let fileId = try await notion.uploadFile(
                    UploadFileRequest(
                        mediaId: item.id,
                        fileURL: fileStore.url(for: path),
                        idempotencyKey: key(state, step: "file-\(item.id.uuidString)")
                    )
                )
                item.markUploaded()
                state.recordUploadedFile(mediaId: item.id, externalFileId: fileId)
                fileIds.append(AttachedFile(id: fileId, kind: item.kind))
            } catch let error as APIError {
                item.markUploadFailed(error.userFacingMessage)
            } catch {
                item.markUploadFailed(error.localizedDescription)
            }
            try? store.flush()
        }

        state.advance(to: .filesUploaded)
        try? store.flush()
        return fileIds
    }

    /// The entry's words, with no media attached to them.
    private func insertText(
        state: SyncState,
        snapshot: ContentSnapshot,
        pageId: String
    ) async throws {
        guard state.phase.rank < SyncPhase.contentInserted.rank else { return }

        let blockIds = try await notion.insertContent(
            InsertContentRequest(
                pageId: pageId,
                formattedText: snapshot.body,
                attachedFiles: [],
                // Blocks from an earlier interrupted attempt, so the server replaces them
                // instead of appending a second copy. (ADR-005)
                previouslyInsertedBlockIds: state.insertedBlockIds,
                idempotencyKey: key(state, step: "insert-content")
            )
        )
        state.insertedBlockIds = blockIds
        state.advance(to: .contentInserted)
        try? store.flush()
    }

    /// One batch of media, appended as its own blocks.
    ///
    /// `replacing` is the batch's *own* previous block ids and nothing else. The server
    /// deletes exactly what it is handed, so passing another stage's ids here would delete
    /// the entry's words to make room for its photographs.
    ///
    /// The empty text is deliberate: `build_entry_blocks` emits nothing for it, so this
    /// appends files and leaves the paragraphs above untouched.
    private func attach(
        _ files: [AttachedFile],
        state: SyncState,
        pageId: String,
        replacing previous: [String],
        step: String,
        reached phase: SyncPhase,
        record: ([String]) -> Void
    ) async throws {
        guard state.phase.rank < phase.rank else { return }

        // Nothing to send and nothing left behind: skip the round trip rather than ask the
        // server to delete nothing and append nothing.
        if files.isEmpty, previous.isEmpty {
            state.advance(to: phase)
            try? store.flush()
            return
        }

        let blockIds = try await notion.insertContent(
            InsertContentRequest(
                pageId: pageId,
                formattedText: "",
                attachedFiles: files,
                previouslyInsertedBlockIds: previous,
                idempotencyKey: key(state, step: step)
            )
        )
        record(blockIds)
        state.advance(to: phase)
        try? store.flush()
    }

    private func updateProperties(
        state: SyncState,
        snapshot: ContentSnapshot,
        pageId: String
    ) async throws {
        guard state.phase.rank < SyncPhase.propertiesUpdated.rank else { return }

        try await notion.updateProperties(
            UpdatePropertiesRequest(
                pageId: pageId,
                title: snapshot.title,
                entryDate: snapshot.entryDate,
                idempotencyKey: key(state, step: "update-props")
            )
        )
        state.advance(to: .propertiesUpdated)
        try? store.flush()
    }

    /// Derives a per-step key from the attempt. Stable across retries of the same content,
    /// which is exactly what lets the backend replay rather than re-write. (ADR-003)
    private func key(_ state: SyncState, step: String) -> IdempotencyKey {
        IdempotencyKey(attemptId: state.attemptId ?? state.id.uuidString, step: step)
    }
}

/// Immutable copy of what a given attempt is sending.
private struct ContentSnapshot: Sendable {
    let contentHash: String
    let title: String?
    let entryDate: CalendarDay
    let body: String
}

public enum SyncOutcome: Sendable, Equatable {
    case synced
    /// Succeeded, but the user edited while it was in flight, so the draft is dirty again.
    case syncedButSupersededByEdits
    case deferred(String)
    case failed(String)
    case nothingToSync
    case vanished
    case alreadyRunning
}

public struct SyncRunSummary: Sendable, Equatable {
    public var synced = 0
    public var deferred = 0
    public var failed = 0
    public var skipped = 0
    public var stoppedEarlyBecause: String?

    public var total: Int { synced + deferred + failed + skipped }
}
