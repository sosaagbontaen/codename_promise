import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// The adversarial suite. "Never lose work" is the product thesis, so these tests simulate
/// the ways it could be false: process death mid-operation, a moved container, network
/// failure at every step. If this suite is green the promise is real; if it is absent the
/// promise is decoration. See ADR-025.
@Suite("Durability")
@MainActor
struct DurabilityTests {

    /// Builds a store, and a second store over the same container to stand in for a
    /// relaunch: a fresh `ModelContext` can only see what was actually committed.
    private func makeContainer() throws -> ModelContainer {
        try ModelContainerFactory.makeInMemoryContainer()
    }

    private func makeFileStore() throws -> (MediaFileStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (MediaFileStore(root: root), root)
    }

    @Test("typed text is committed, not merely held in memory")
    func typedTextSurvivesRelaunch() throws {
        let container = try makeContainer()
        let draftId: UUID

        do {
            let store = DraftStore(container: container)
            let draft = try store.createDraft()
            draftId = draft.id
            try store.updateRawText("Three things went well today.", for: draft)
        }

        let reopened = DraftStore(container: container)
        let recovered = try reopened.draft(id: draftId)
        #expect(recovered?.content.rawText == "Three things went well today.")
    }

    /// The founding bug. Audio must be on disk and committed *before* transcription is
    /// attempted, so losing the network — or the process — costs convenience, never words.
    @Test("dictation audio is durable before transcription is attempted")
    func audioPersistsBeforeTranscription() throws {
        let container = try makeContainer()
        let (fileStore, _) = try makeFileStore()
        let audio = Data(repeating: 0xAB, count: 4096)
        let draftId: UUID
        let capturePath: String

        do {
            let store = DraftStore(container: container)
            let draft = try store.createDraft()
            draftId = draft.id
            let capture = try store.attachAudioCapture(
                data: audio,
                fileExtension: "m4a",
                durationSeconds: 42,
                to: draft,
                fileStore: fileStore
            )
            capturePath = capture.relativePath
            // Transcription has not run. Simulate the process dying right here.
            #expect(capture.transcriptionStatus == .pending)
        }

        #expect(fileStore.exists(capturePath), "audio bytes must be on disk")

        let reopened = DraftStore(container: container)
        let recovered = try #require(try reopened.draft(id: draftId))
        #expect(recovered.audioCaptures.count == 1)

        let pending = try reopened.pendingTranscriptions()
        #expect(pending.count == 1, "the recording must come back as retryable work")
        #expect(pending.first?.isSafeToDelete == false)
    }

    @Test("audio is only releasable once its transcript is committed to the draft")
    func audioHeldUntilTranscriptMerged() throws {
        let container = try makeContainer()
        let (fileStore, _) = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        let capture = try store.attachAudioCapture(
            data: Data(repeating: 1, count: 128),
            fileExtension: "m4a",
            durationSeconds: 5,
            to: draft,
            fileStore: fileStore
        )
        #expect(capture.isSafeToDelete == false)

        try store.mergeTranscript("Had a good run this morning.", from: capture, into: draft)

        #expect(capture.isSafeToDelete)
        #expect(draft.content.rawText.contains("Had a good run this morning."))
    }

    /// Restore-from-backup simulation. The container UUID changes on restore, so any
    /// absolute path stored in the database would dangle. Relative paths survive.
    @Test("media references survive the container moving")
    func mediaSurvivesContainerMove() throws {
        let (originalStore, originalRoot) = try makeFileStore()
        let source = originalRoot.appendingPathComponent("incoming.jpg")
        try Data(repeating: 0x42, count: 2048).write(to: source)

        let adopted = try originalStore.adopt(fileAt: source)
        #expect(adopted.sizeBytes == 2048)
        #expect(adopted.relativePath.hasPrefix("media/"))
        #expect(!adopted.relativePath.hasPrefix("/"), "stored paths must never be absolute")

        // "Restore": the same tree at a brand-new location.
        let newRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-restored-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: originalRoot, to: newRoot)
        try FileManager.default.removeItem(at: originalRoot)

        let restored = MediaFileStore(root: newRoot)
        #expect(restored.exists(adopted.relativePath), "the same relative path must resolve after a move")
        #expect(restored.sizeBytes(of: adopted.relativePath) == 2048)
    }

    @Test("attaching media copies the bytes, so purging the source is harmless")
    func attachCopiesBytes() throws {
        let container = try makeContainer()
        let (fileStore, root) = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        // Stand in for the transient URL PhotosPicker hands over.
        let transient = root.appendingPathComponent("temp-from-picker.png")
        try Data(repeating: 0x7F, count: 1024).write(to: transient)

        let item = try store.attachMedia(from: transient, kind: .photo, to: draft, fileStore: fileStore)
        try FileManager.default.removeItem(at: transient)

        #expect(fileStore.exists(item.relativePath), "the photo must outlive the picker's temp file")
        #expect(item.originalSizeBytes == 1024)
    }

    @Test("removing media deletes the row and the bytes")
    func removingMediaDeletesFiles() throws {
        let container = try makeContainer()
        let (fileStore, root) = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        let source = root.appendingPathComponent("shot.png")
        try Data(repeating: 3, count: 512).write(to: source)
        let item = try store.attachMedia(from: source, kind: .photo, to: draft, fileStore: fileStore)
        let path = item.relativePath

        try store.removeMedia(id: item.id, from: draft, fileStore: fileStore)

        #expect(draft.media.isEmpty)
        #expect(fileStore.exists(path) == false, "cascade deletes rows; files need deleting too")
    }

    @Test("deleting a draft reclaims all of its bytes")
    func deletingDraftReclaimsBytes() throws {
        let container = try makeContainer()
        let (fileStore, root) = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        let source = root.appendingPathComponent("clip.mov")
        try Data(repeating: 9, count: 256).write(to: source)
        let media = try store.attachMedia(from: source, kind: .video, to: draft, fileStore: fileStore)
        let audio = try store.attachAudioCapture(
            data: Data(repeating: 8, count: 256),
            fileExtension: "m4a",
            durationSeconds: 3,
            to: draft,
            fileStore: fileStore
        )
        let paths = [media.relativePath, audio.relativePath]

        try store.delete(draft, fileStore: fileStore)

        for path in paths {
            #expect(fileStore.exists(path) == false)
        }
    }

    @Test("orphan reaping removes unclaimed bytes and keeps claimed ones")
    func reapsOnlyOrphans() throws {
        let container = try makeContainer()
        let (fileStore, root) = try makeFileStore()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()

        let source = root.appendingPathComponent("keep.png")
        try Data(repeating: 5, count: 64).write(to: source)
        let kept = try store.attachMedia(from: source, kind: .photo, to: draft, fileStore: fileStore)

        // A crash between `adopt` and the model save leaves exactly this: bytes, no row.
        let orphan = try fileStore.write(Data(repeating: 6, count: 64), preferredName: "original", extension: "png")

        let removed = fileStore.reapOrphans(claimedRelativePaths: try store.claimedRelativePaths())

        #expect(removed.contains(orphan.relativePath))
        #expect(fileStore.exists(kept.relativePath), "claimed files must never be reaped")
    }

    @Test("media order is stable across relaunches")
    func mediaOrderIsStable() throws {
        let container = try makeContainer()
        let (fileStore, root) = try makeFileStore()
        let draftId: UUID
        var expected: [UUID] = []

        do {
            let store = DraftStore(container: container)
            let draft = try store.createDraft()
            draftId = draft.id
            for index in 0..<5 {
                let source = root.appendingPathComponent("photo-\(index).png")
                try Data(repeating: UInt8(index), count: 32).write(to: source)
                let item = try store.attachMedia(from: source, kind: .photo, to: draft, fileStore: fileStore)
                expected.append(item.id)
            }
        }

        let reopened = DraftStore(container: container)
        let recovered = try #require(try reopened.draft(id: draftId))
        #expect(recovered.orderedMedia.map(\.id) == expected)
        #expect(recovered.orderedMedia.map(\.sortIndex) == [0, 1, 2, 3, 4])
    }
}

@Suite("Interrupted operations")
@MainActor
struct RecoveryTests {

    /// Without a lease, a kill mid-sync leaves `status == .syncing` — documented as
    /// "don't retry" — permanently. The draft becomes unsyncable with no user-visible way
    /// out. See ADR-004.
    @Test("a sync abandoned by a dead process becomes retryable again")
    func abandonedSyncIsRecovered() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let draftId: UUID

        do {
            let store = DraftStore(container: container, clock: { start })
            let draft = try store.createDraft()
            draftId = draft.id
            try store.updateRawText("today", for: draft)
            let state = draft.syncState(for: .notion)
            state.beginAttempt(contentHash: draft.contentHash, now: start)
            state.advance(to: .pageEnsured)
            state.externalId = "page-42"
            try store.flush()
            #expect(state.status == .syncing)
        }

        // Relaunch, ten minutes later.
        let later = start.addingTimeInterval(600)
        let reopened = DraftStore(container: container, clock: { later })
        let report = try reopened.reconcileAbandonedOperations()

        #expect(report.recoveredSyncStates == 1)

        let draft = try #require(try reopened.draft(id: draftId))
        let state = draft.syncState(for: .notion)
        #expect(state.status == .failed)
        #expect(state.lastSyncError != nil)
        #expect(draft.needsSync(to: .notion), "recovery must leave it retryable")
        #expect(state.phase == .pageEnsured, "progress is kept so the retry resumes")
        #expect(state.externalId == "page-42")
    }

    @Test("a sync that is genuinely in flight is left alone")
    func freshSyncIsNotDisturbed() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let store = DraftStore(container: container, clock: { start })
        let draft = try store.createDraft()
        draft.syncState(for: .notion).beginAttempt(contentHash: draft.contentHash, now: start)
        try store.flush()

        let barelyLater = DraftStore(container: container, clock: { start.addingTimeInterval(5) })
        let report = try barelyLater.reconcileAbandonedOperations()

        #expect(report.isEmpty)
    }

    @Test("an interrupted transcription returns as pending work, not as a failure")
    func abandonedTranscriptionIsRequeued() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStore = MediaFileStore(root: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let draftId: UUID
        do {
            let store = DraftStore(container: container, clock: { start })
            let draft = try store.createDraft()
            draftId = draft.id
            let capture = try store.attachAudioCapture(
                data: Data(repeating: 1, count: 64),
                fileExtension: "m4a",
                durationSeconds: 9,
                to: draft,
                fileStore: fileStore
            )
            capture.markTranscribing(now: start)
            try store.flush()
        }

        let later = DraftStore(container: container, clock: { start.addingTimeInterval(600) })
        let report = try later.reconcileAbandonedOperations()

        #expect(report.recoveredTranscriptions == 1)
        // Re-read through the store that did the reconciling. Each DraftStore owns its own
        // ModelContext, so an object fetched from one does not observe another's writes —
        // which is exactly why the app has a single store on the main actor (ADR-009a).
        let draft = try #require(try later.draft(id: draftId))
        #expect(draft.orderedAudioCaptures.first?.transcriptionStatus == .pending)
        #expect(try later.pendingTranscriptions().count == 1)
    }

    @Test("an interrupted upload becomes retryable and keeps its attempt count")
    func abandonedUploadIsRecovered() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileStore = MediaFileStore(root: root)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        let draftId: UUID
        do {
            let store = DraftStore(container: container, clock: { start })
            let draft = try store.createDraft()
            draftId = draft.id
            let source = root.appendingPathComponent("a.png")
            try Data(repeating: 2, count: 32).write(to: source)
            let item = try store.attachMedia(from: source, kind: .photo, to: draft, fileStore: fileStore)
            item.markUploading(now: start)
            try store.flush()
        }

        let later = DraftStore(container: container, clock: { start.addingTimeInterval(600) })
        #expect(try later.reconcileAbandonedOperations().recoveredUploads == 1)

        let draft = try #require(try later.draft(id: draftId))
        let item = try #require(draft.orderedMedia.first)
        #expect(item.uploadStatus == .failed)
        #expect(item.uploadAttemptCount == 1, "the attempt count must survive recovery so backoff can work")
        #expect(item.uploadError != nil)
    }
}

@Suite("Sync idempotency")
@MainActor
struct SyncIdempotencyTests {

    /// A lost 200 followed by a retry must not insert the entry twice. The key is what lets
    /// the backend replay the original result instead of writing again. See ADR-003.
    @Test("retrying the same content reuses the idempotency key")
    func keyIsStableAcrossRetries() {
        let draft = EntryDraft()
        draft.updateRawText("v1")
        let state = draft.syncState(for: .notion)

        state.beginAttempt(contentHash: draft.contentHash)
        let firstKey = state.attemptId
        state.advance(to: .pageEnsured)
        state.markFailed("connection lost")

        state.beginAttempt(contentHash: draft.contentHash)

        #expect(state.attemptId == firstKey)
        #expect(state.phase == .pageEnsured, "a resume must not discard recorded progress")
        #expect(state.attemptCount == 2)
    }

    @Test("changed content earns a fresh key and restarts the phases")
    func keyRotatesOnContentChange() {
        let draft = EntryDraft()
        draft.updateRawText("v1")
        let state = draft.syncState(for: .notion)

        state.beginAttempt(contentHash: draft.contentHash)
        let firstKey = state.attemptId
        state.advance(to: .filesUploaded)
        state.recordUploadedFile(mediaId: UUID(), externalFileId: "file-1")
        state.markFailed("timeout")

        draft.updateRawText("v2 — actually different")
        state.beginAttempt(contentHash: draft.contentHash)

        #expect(state.attemptId != firstKey)
        #expect(state.phase == .notStarted)
        // Destination state survives the rotation. This assertion originally read
        // `uploadedFileIds.isEmpty` on the reasoning that a different write shouldn't reuse old
        // uploads — which was wrong, and would have duplicated the entry in the destination on
        // every edit. What already exists remotely is not attempt-scoped.
        #expect(state.uploadedFileIds.isEmpty == false,
                "already-uploaded files stay known, so a re-sync references rather than re-uploads")
    }

    @Test("resumed uploads are not repeated")
    func uploadedFilesAreRemembered() {
        let draft = EntryDraft()
        draft.updateRawText("with photos")
        let state = draft.syncState(for: .notion)
        state.beginAttempt(contentHash: draft.contentHash)

        let mediaId = UUID()
        state.recordUploadedFile(mediaId: mediaId, externalFileId: "notion-file-9")

        #expect(state.uploadedFileId(for: mediaId) == "notion-file-9")
        #expect(state.uploadedFileId(for: UUID()) == nil)
    }

    @Test("phases never move backwards")
    func phasesAreMonotonic() {
        let state = SyncState(target: .notion)
        state.advance(to: .contentInserted)
        state.advance(to: .pageEnsured)
        #expect(state.phase == .contentInserted)
    }

    @Test("a successful sync clears the in-flight bookkeeping")
    func successClearsAttempt() {
        let draft = EntryDraft()
        draft.updateRawText("done")
        let state = draft.syncState(for: .notion)
        state.beginAttempt(contentHash: draft.contentHash)
        state.markSynced(externalId: "page-7", contentHash: draft.contentHash)

        #expect(state.attemptId == nil)
        #expect(state.startedAt == nil)
        #expect(state.status == .synced)
        #expect(state.phase.isComplete)
        #expect(state.isStale(now: Date().addingTimeInterval(10_000), timeout: 60) == false)
    }
}

@Suite("Schema")
struct SchemaTests {

    @Test("the container is built from a versioned schema with a migration plan")
    func schemaIsVersioned() throws {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
        #expect(SchemaV1.models.count == 4)
        #expect(SchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
        #expect(CodenamePromiseMigrationPlan.schemas.count == 2)
        #expect(CodenamePromiseMigrationPlan.stages.count == 1,
                "a version bump without a stage is what refused to open the store")
        _ = try ModelContainerFactory.makeInMemoryContainer()
    }
}

@Suite("Empty transcripts")
@MainActor
struct EmptyTranscriptTests {

    private func makeStore() throws -> (DraftStore, MediaFileStore) {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DraftStore(container: container), MediaFileStore(root: root))
    }

    /// The silent-success bug. A blank transcript used to mark the recording complete: the
    /// "waiting to transcribe" notice vanished, no words appeared, nothing was reported.
    @Test("a blank transcript does not retire the recording")
    func blankTranscriptIsNotSuccess() throws {
        let (store, files) = try makeStore()
        let draft = try store.createDraft()
        let capture = try store.attachAudioCapture(
            data: Data(repeating: 1, count: 64), fileExtension: "m4a",
            durationSeconds: 4, to: draft, fileStore: files
        )

        let merged = try store.mergeTranscript("", from: capture, into: draft)

        #expect(merged == false)
        #expect(capture.isSafeToDelete == false, "the audio must still be held")
        #expect(capture.mergedIntoDraftAt == nil)
    }

    @Test("whitespace counts as blank")
    func whitespaceIsBlank() throws {
        let (store, files) = try makeStore()
        let draft = try store.createDraft()
        let capture = try store.attachAudioCapture(
            data: Data(repeating: 1, count: 64), fileExtension: "m4a",
            durationSeconds: 4, to: draft, fileStore: files
        )
        #expect(try store.mergeTranscript("   \n  ", from: capture, into: draft) == false)
    }

    @Test("a real transcript is merged and trimmed")
    func realTranscriptMerges() throws {
        let (store, files) = try makeStore()
        let draft = try store.createDraft()
        let capture = try store.attachAudioCapture(
            data: Data(repeating: 1, count: 64), fileExtension: "m4a",
            durationSeconds: 4, to: draft, fileStore: files
        )

        #expect(try store.mergeTranscript("  Went to the airport.  ", from: capture, into: draft))
        #expect(draft.content.rawText == "Went to the airport.")
        #expect(capture.isSafeToDelete)
    }
}

@Suite("Duplicating an entry")
@MainActor
struct DuplicateTests {

    private func makeHarness() throws -> (DraftStore, MediaFileStore, URL) {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-dup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (DraftStore(container: container), MediaFileStore(root: root), root)
    }

    @Test("a copy carries the words, the title and the day")
    func copiesContent() throws {
        let (store, files, _) = try makeHarness()
        let original = try store.createDraft()
        try store.updateRawText("Three things went well.", for: original)
        try store.updateTitle("Tuesday", for: original)

        let copy = try store.duplicate(original, fileStore: files)

        #expect(copy.content.rawText == "Three things went well.")
        #expect(copy.content.title == "Tuesday")
        #expect(copy.entryDate == original.entryDate)
        #expect(copy.id != original.id)
    }

    /// Sharing one file between two rows would mean deleting either entry destroys the
    /// other's photo, because deletion removes the bytes (ADR-018a).
    @Test("media bytes are duplicated, not shared")
    func duplicatesBytes() throws {
        let (store, files, root) = try makeHarness()
        let original = try store.createDraft()
        let source = root.appendingPathComponent("shot.png")
        try Data(repeating: 7, count: 512).write(to: source)
        try store.attachMedia(from: source, kind: .photo, to: original, fileStore: files)

        let copy = try store.duplicate(original, fileStore: files)
        let originalPath = original.orderedMedia[0].relativePath
        let copyPath = copy.orderedMedia[0].relativePath

        #expect(copyPath != originalPath, "two rows must not point at one file")
        #expect(files.exists(copyPath))

        // Deleting the copy must leave the original's photo intact.
        try store.delete(copy, fileStore: files)
        #expect(files.exists(originalPath))
    }

    /// Inheriting a page id would make the clone overwrite the original's Notion page.
    @Test("a copy is not synced anywhere")
    func doesNotInheritSyncState() throws {
        let (store, files, _) = try makeHarness()
        let original = try store.createDraft()
        try store.updateRawText("Already pushed.", for: original)
        original.syncState(for: .notion).markSynced(
            externalId: "page-1", contentHash: original.contentHash
        )

        let copy = try store.duplicate(original, fileStore: files)

        #expect(copy.syncStates.first(where: { $0.target == .notion })?.externalId == nil)
        #expect(copy.needsSync(to: .notion))
    }

    @Test("dictation audio is not duplicated, so nothing transcribes twice")
    func doesNotCopyAudio() throws {
        let (store, files, _) = try makeHarness()
        let original = try store.createDraft()
        try store.attachAudioCapture(
            data: Data(repeating: 1, count: 64), fileExtension: "m4a",
            durationSeconds: 3, to: original, fileStore: files
        )

        let copy = try store.duplicate(original, fileStore: files)

        #expect(copy.audioCaptures.isEmpty)
        #expect(original.audioCaptures.count == 1, "the original keeps its recording")
    }

    @Test("formatted text and its prompt version come along")
    func copiesFormatting() throws {
        let (store, files, _) = try makeHarness()
        let original = try store.createDraft()
        try store.updateRawText("raw", for: original)
        try store.applyFormatting("- raw", formatterVersion: "wwwt-1", to: original)

        let copy = try store.duplicate(original, fileStore: files)

        #expect(copy.content.formattedText == "- raw")
        #expect(copy.content.formatterVersion == "wwwt-1")
    }
}
