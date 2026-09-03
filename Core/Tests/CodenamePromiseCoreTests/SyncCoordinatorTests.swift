import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// A Notion stand-in that records every call and can be told to fail at a chosen step.
///
/// It also models the thing the whole idempotency design exists for: `insertContent` appends
/// to a `pageContents` log unless the caller supplies block IDs to replace. If the coordinator
/// ever re-inserts, this stub shows a duplicated page — which is precisely the user-visible
/// corruption ADR-003 and ADR-005 are meant to prevent.
actor StubNotionAPI: NotionAPI {
    enum Step: String { case ensurePage, uploadFile, insertContent, updateProperties }

    private(set) var callCounts: [String: Int] = [:]
    private(set) var seenKeys: [String: [String]] = [:]
    /// Block id -> body, standing in for the destination page's actual contents.
    private(set) var pageContents: [String: String] = [:]

    private var failAt: (step: Step, error: APIError)?
    private var nextBlockId = 0

    func setFailure(_ step: Step?, error: APIError = .server(status: 503, message: nil)) {
        failAt = step.map { ($0, error) }
    }

    func callCount(_ step: Step) -> Int { callCounts[step.rawValue] ?? 0 }
    func keys(_ step: Step) -> [String] { seenKeys[step.rawValue] ?? [] }
    var pageBodyCount: Int { pageContents.count }

    private func record(_ step: Step, key: String) throws {
        callCounts[step.rawValue, default: 0] += 1
        seenKeys[step.rawValue, default: []].append(key)
        if let failAt, failAt.step == step { throw failAt.error }
    }

    func ensurePage(_ request: EnsurePageRequest) async throws -> String {
        try record(.ensurePage, key: request.idempotencyKey.rawValue)
        // Honours a page the client already has, exactly as the real backend does. The stub
        // used to ignore `existingExternalId` and always mint a page from the date — which
        // meant a test could pass while the client's chosen page was being discarded.
        if let existing = request.existingExternalId, !existing.isEmpty {
            return existing
        }
        return "page-\(request.entryDate.rawValue)-\(pageCounter())"
    }

    private var nextPage = 0
    private func pageCounter() -> Int {
        nextPage += 1
        return nextPage
    }

    func uploadFile(_ request: UploadFileRequest) async throws -> String {
        try record(.uploadFile, key: request.idempotencyKey.rawValue)
        return "file-\(request.mediaId.uuidString.prefix(8))"
    }

    func insertContent(_ request: InsertContentRequest) async throws -> [String] {
        try record(.insertContent, key: request.idempotencyKey.rawValue)
        for id in request.previouslyInsertedBlockIds { pageContents.removeValue(forKey: id) }
        nextBlockId += 1
        let blockId = "block-\(nextBlockId)"
        pageContents[blockId] = request.formattedText
        return [blockId]
    }

    func updateProperties(_ request: UpdatePropertiesRequest) async throws {
        try record(.updateProperties, key: request.idempotencyKey.rawValue)
    }
}

@Suite("Sync coordinator")
@MainActor
struct SyncCoordinatorTests {

    private struct Harness {
        let store: DraftStore
        let files: MediaFileStore
        let draft: EntryDraft
        let root: URL
    }

    private func makeHarness(now: Date, text: String = "Three things went well.") throws -> Harness {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MediaFileStore(root: root)
        let store = DraftStore(container: container, clock: { now })
        let draft = try store.createDraft()
        try store.updateRawText(text, for: draft)
        return Harness(store: store, files: files, draft: draft, root: root)
    }

    @discardableResult
    private func attachPhoto(_ h: Harness, name: String) throws -> MediaItem {
        let source = h.root.appendingPathComponent(name)
        try Data(repeating: 7, count: 128).write(to: source)
        return try h.store.attachMedia(from: source, kind: .photo, to: h.draft, fileStore: h.files)
    }

    // MARK: - Happy path

    @Test("a clean sync walks every phase once and marks the draft synced")
    func happyPath() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        let outcome = await sut.sync(draftId: h.draft.id)

        #expect(outcome == .synced)
        #expect(await api.callCount(.ensurePage) == 1)
        #expect(await api.callCount(.insertContent) == 1)
        #expect(await api.callCount(.updateProperties) == 1)

        let state = h.draft.syncState(for: .notion)
        #expect(state.status == .synced)
        #expect(state.phase.isComplete)
        #expect(state.externalId?.hasPrefix("page-\(h.draft.entryDate.rawValue)") == true)
        #expect(h.draft.needsSync(to: .notion) == false)
        #expect(state.attemptId == nil, "a finished attempt clears its idempotency key")
    }

    @Test("an unformatted draft still syncs, using the user's own words")
    func unformattedDraftSyncs() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now, text: "Raw and unpolished, but mine.")
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        let bodies = await api.pageContents.values
        #expect(bodies.contains("Raw and unpolished, but mine."))
    }

    @Test("an empty draft is not pushed anywhere")
    func emptyDraftSkipped() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = DraftStore(container: container, clock: { now })
        let draft = try store.createDraft()
        let api = StubNotionAPI()
        let files = MediaFileStore(root: FileManager.default.temporaryDirectory)
        let sut = SyncCoordinator(store: store, fileStore: files, notion: api, clock: { now })

        #expect(await sut.sync(draftId: draft.id) == .nothingToSync)
        #expect(await api.callCount(.ensurePage) == 0)
    }

    // MARK: - The duplication guarantee

    /// The headline regression. A successful `insertContent` whose response is lost, followed
    /// by a retry, must not put the entry in the destination twice.
    @Test("a failure after insertContent does not re-insert on retry")
    func retryDoesNotDuplicateContent() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        // Content lands, then the very next step fails — the classic lost-response shape.
        await api.setFailure(.updateProperties)
        let first = await sut.sync(draftId: h.draft.id)
        #expect(first == .deferred("The server had a problem. Saved on this device."))
        #expect(await api.callCount(.insertContent) == 1)
        #expect(await api.pageBodyCount == 1)

        await api.setFailure(nil)
        let second = await sut.sync(draftId: h.draft.id)

        #expect(second == .synced)
        #expect(await api.callCount(.insertContent) == 1, "the retry must resume, not re-insert")
        #expect(await api.callCount(.ensurePage) == 1, "an ensured page is not re-ensured")
        #expect(await api.pageBodyCount == 1, "the entry appears in the destination exactly once")
        #expect(await api.callCount(.updateProperties) == 2)
    }

    @Test("retries of the same content reuse the same idempotency keys")
    func keysAreStableAcrossRetries() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        await api.setFailure(.ensurePage)
        _ = await sut.sync(draftId: h.draft.id)
        await api.setFailure(nil)
        _ = await sut.sync(draftId: h.draft.id)

        let keys = await api.keys(.ensurePage)
        #expect(keys.count == 2)
        #expect(keys[0] == keys[1], "the backend can only dedupe if the key is stable")
    }

    @Test("editing between attempts rotates the key and re-runs the phases")
    func editingRotatesTheAttempt() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        let firstKeys = await api.keys(.insertContent)

        try h.store.updateRawText("Actually, four things went well.", for: h.draft)
        #expect(h.draft.needsSync(to: .notion))

        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        let allKeys = await api.keys(.insertContent)

        #expect(allKeys.count == 2)
        #expect(allKeys[0] != allKeys[1], "different content is a genuinely different write")
        #expect(firstKeys.first == allKeys.first)
        // The old block was replaced rather than joined by a second copy.
        #expect(await api.pageBodyCount == 1)
        let bodies = await api.pageContents.values
        #expect(bodies.contains("Actually, four things went well."))
    }

    // MARK: - Media resilience

    /// From the founding list of problems: "Upload failures causing the entire entry to fail."
    @Test("a photo that won't upload does not stop the entry syncing")
    func mediaFailureDoesNotFailTheEntry() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let item = try attachPhoto(h, name: "shot.png")
        let api = StubNotionAPI()
        await api.setFailure(.uploadFile, error: .server(status: 500, message: "storage down"))
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        let outcome = await sut.sync(draftId: h.draft.id)

        #expect(outcome == .synced, "the words must get through regardless")
        #expect(item.uploadStatus == .failed)
        #expect(item.uploadError != nil)
        #expect(await api.callCount(.insertContent) == 1)
        #expect(h.draft.syncState(for: .notion).status == .synced)
    }

    @Test("media missing from disk is reported, not retried into a loop")
    func missingMediaIsSkipped() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let item = try attachPhoto(h, name: "gone.png")
        h.files.delete(relativePaths: [item.relativePath])
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        #expect(await api.callCount(.uploadFile) == 0)
        #expect(item.uploadStatus == .failed)
    }

    @Test("a resumed sync does not re-upload files it already sent")
    func uploadsAreNotRepeatedOnResume() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        try attachPhoto(h, name: "a.png")
        try attachPhoto(h, name: "b.png")
        let api = StubNotionAPI()
        await api.setFailure(.insertContent)
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        _ = await sut.sync(draftId: h.draft.id)
        #expect(await api.callCount(.uploadFile) == 2)

        await api.setFailure(nil)
        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        #expect(await api.callCount(.uploadFile) == 2, "already-uploaded files must not be re-sent")
    }

    // MARK: - Interruption and concurrency

    @Test("a sync stranded by a process death is recovered and resumes")
    func strandedSyncResumes() async throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MediaFileStore(root: root)
        let api = StubNotionAPI()
        let draftId: UUID

        do {
            let store = DraftStore(container: container, clock: { start })
            let draft = try store.createDraft()
            draftId = draft.id
            try store.updateRawText("Interrupted mid-push.", for: draft)
            let sut = SyncCoordinator(store: store, fileStore: files, notion: api, clock: { start })
            await api.setFailure(.insertContent, error: .transport("killed"))
            _ = await sut.sync(draftId: draftId)
            // Leave it looking in-flight, as a SIGKILL would.
            let state = draft.syncState(for: .notion)
            state.status = .syncing
            state.startedAt = start
            try store.flush()
        }

        let later = start.addingTimeInterval(600)
        let reopened = DraftStore(container: container, clock: { later })
        #expect(try reopened.reconcileAbandonedOperations().recoveredSyncStates == 1)

        await api.setFailure(nil)
        let sut = SyncCoordinator(store: reopened, fileStore: files, notion: api, clock: { later })
        #expect(await sut.sync(draftId: draftId) == .synced)

        #expect(await api.callCount(.ensurePage) == 1, "recovery kept the page it had already made")
        #expect(await api.pageBodyCount == 1)
    }

    @Test("editing while a sync is in flight is reported, not silently lost")
    func editDuringSyncIsReported() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = HookedNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        // Fires between the snapshot being taken and the attempt finishing — deterministically
        // reproducing "the user kept typing while it was uploading".
        api.duringInsert = {
            try? h.store.updateRawText("Changed my mind halfway through.", for: h.draft)
        }

        let result = await sut.sync(draftId: h.draft.id)

        #expect(result == .syncedButSupersededByEdits)
        #expect(h.draft.needsSync(to: .notion), "the newer text is correctly still pending")
        #expect(h.draft.content.rawText == "Changed my mind halfway through.",
                "the in-flight sync must not clobber what the user typed")
    }

    @Test("a second sync of the same draft while one is running is refused")
    func overlappingSyncIsRefused() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = HookedNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        var reentrantOutcome: SyncOutcome?
        api.duringInsert = {
            reentrantOutcome = await sut.sync(draftId: h.draft.id)
        }

        #expect(await sut.sync(draftId: h.draft.id) == .synced)
        #expect(reentrantOutcome == .alreadyRunning)
        #expect(api.insertCount == 1, "one draft, one insert")
    }

    // MARK: - Batch

    @Test("syncing everything dirty stops early when the whole queue would fail")
    func batchStopsEarlyWhenBlocked() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let second = try h.store.createDraft()
        try h.store.updateRawText("Another day, another entry.", for: second)

        let api = StubNotionAPI()
        await api.setFailure(.ensurePage, error: .offline)
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        let summary = await sut.syncAllDirty()

        #expect(summary.synced == 0)
        #expect(summary.deferred == 1)
        #expect(summary.stoppedEarlyBecause != nil)
        #expect(await api.callCount(.ensurePage) == 1, "no point trying the rest while offline")
    }

    @Test("only dirty drafts are pushed")
    func batchSkipsCleanDrafts() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: h.store, fileStore: h.files, notion: api, clock: { now })

        #expect(await sut.syncAllDirty().synced == 1)
        let afterFirst = await api.callCount(.insertContent)

        let summary = await sut.syncAllDirty()
        #expect(summary.synced == 0)
        #expect(await api.callCount(.insertContent) == afterFirst, "a clean draft is not re-pushed")
    }
}

/// Main-actor stub with a hook that runs mid-attempt.
///
/// Isolated to the main actor precisely so it can touch the store and models — which is what
/// makes "the user edits while a sync is in flight" testable without racing. A `@MainActor
/// final class` is implicitly `Sendable`, so it satisfies `NotionAPI`.
@MainActor
final class HookedNotionAPI: NotionAPI {
    var duringInsert: (() async -> Void)?
    private(set) var insertCount = 0

    func ensurePage(_ request: EnsurePageRequest) async throws -> String {
        "page-\(request.entryDate.rawValue)"
    }

    func uploadFile(_ request: UploadFileRequest) async throws -> String {
        "file-\(request.mediaId.uuidString.prefix(8))"
    }

    func insertContent(_ request: InsertContentRequest) async throws -> [String] {
        insertCount += 1
        await duringInsert?()
        return ["block-\(insertCount)"]
    }

    func updateProperties(_ request: UpdatePropertiesRequest) async throws {}
}

@Suite("Destination changes")
@MainActor
struct DestinationChangeTests {

    /// The bug this exists for: a client synced against a development stub kept the fake file
    /// IDs it handed back, then pointed at real Notion, skipped re-uploading because it
    /// "already had" IDs, and sent fabrications — which Notion rejected with an error that
    /// looked like Notion's fault.
    @Test("switching destination discards IDs the new destination never issued")
    func switchingDestinationResets() {
        let draft = EntryDraft()
        draft.updateRawText("An entry")
        let state = draft.syncState(for: .notion)

        state.adoptDestination("stub-destination")
        state.externalId = "page-from-the-stub"
        state.recordUploadedFile(mediaId: UUID(), externalFileId: "file-fake-1")
        state.insertedBlockIds = ["block-fake-1"]
        state.markSynced(externalId: "page-from-the-stub", contentHash: draft.contentHash)

        let reset = state.adoptDestination("real-notion-workspace")

        #expect(reset, "the caller should be able to report that this happened")
        #expect(state.externalId == nil)
        #expect(state.uploadedFileIds.isEmpty)
        #expect(state.insertedBlockIds.isEmpty)
        #expect(state.status != .synced, "it was never synced to *this* destination")
        #expect(draft.needsSync(to: .notion), "so it must be pushed afresh")
    }

    @Test("staying on the same destination keeps everything")
    func sameDestinationKeepsState() {
        let draft = EntryDraft()
        draft.updateRawText("An entry")
        let state = draft.syncState(for: .notion)
        state.adoptDestination("workspace-a")
        state.externalId = "page-1"
        state.recordUploadedFile(mediaId: UUID(), externalFileId: "file-1")

        let reset = state.adoptDestination("workspace-a")

        #expect(reset == false)
        #expect(state.externalId == "page-1", "resetting here would duplicate the entry")
        #expect(state.uploadedFileIds.count == 1)
    }

    @Test("an unknown destination fingerprint changes nothing")
    func unknownFingerprintIsIgnored() {
        let state = SyncState(target: .notion)
        state.adoptDestination("workspace-a")
        state.externalId = "page-1"

        // Backend not ready, or not reporting one — no information is not a reason to discard.
        #expect(state.adoptDestination(nil) == false)
        #expect(state.externalId == "page-1")
    }

    @Test("adopting a destination for the first time is not a reset")
    func firstAdoptionIsNotAReset() {
        let state = SyncState(target: .notion)
        #expect(state.adoptDestination("workspace-a") == false, "nothing was discarded")
        #expect(state.destinationFingerprint == "workspace-a")
    }
}

@Suite("Appending to an existing entry")
@MainActor
struct AppendModeTests {

    private func makeDraft() -> (DraftStore, EntryDraft, MediaFileStore) {
        let container = try! ModelContainerFactory.makeInMemoryContainer()
        let store = DraftStore(container: container)
        let draft = try! store.createDraft()
        try! store.updateRawText("More thoughts to add", for: draft)
        return (store, draft, MediaFileStore(root: FileManager.default.temporaryDirectory))
    }

    @Test("attaching to an existing page marks it as not ours")
    func attachingMarksAppendMode() {
        let (_, draft, _) = makeDraft()
        let state = draft.syncState(for: .notion)

        state.attachToExistingPage("their-page-id")

        #expect(state.externalId == "their-page-id")
        #expect(state.appendsToExistingPage)
        #expect(draft.needsSync(to: .notion))
    }

    /// The whole point of append mode: their page keeps its title and date.
    @Test("appending never rewrites the page's properties")
    func appendingLeavesPropertiesAlone() async {
        let (store, draft, files) = makeDraft()
        draft.syncState(for: .notion).attachToExistingPage("their-page-id")
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: store, fileStore: files, notion: api)

        #expect(await sut.sync(draftId: draft.id) == .synced)
        #expect(await api.callCount(.updateProperties) == 0, "that is their entry's title")
        #expect(await api.callCount(.insertContent) == 1)
    }

    @Test("a page we created does get its properties written")
    func ownedPagesGetProperties() async {
        let (store, draft, files) = makeDraft()
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: store, fileStore: files, notion: api)

        #expect(await sut.sync(draftId: draft.id) == .synced)
        #expect(await api.callCount(.updateProperties) == 1)
    }

    @Test("re-syncing an appended entry replaces only the blocks we wrote")
    func appendingReplacesOnlyOurBlocks() async {
        let (store, draft, files) = makeDraft()
        draft.syncState(for: .notion).attachToExistingPage("their-page-id")
        let api = StubNotionAPI()
        let sut = SyncCoordinator(store: store, fileStore: files, notion: api)

        _ = await sut.sync(draftId: draft.id)
        try? store.updateRawText("More thoughts to add, revised", for: draft)
        _ = await sut.sync(draftId: draft.id)

        // Our first block was replaced rather than joined by a second copy, and we never
        // touched anything else on the page.
        #expect(await api.pageBodyCount == 1)
    }

    @Test("unlinking clears append mode too")
    func unlinkClearsAppendMode() {
        let (_, draft, _) = makeDraft()
        let state = draft.syncState(for: .notion)
        state.attachToExistingPage("their-page-id")

        state.unlinkFromDestination()

        #expect(state.appendsToExistingPage == false)
        #expect(state.externalId == nil)
    }
}

@Suite("Sync progress")
struct SyncProgressTests {

    @Test("progress only ever moves forward through the phases")
    func progressIsMonotonic() {
        let steps: [SyncProgress] = [
            .preparing, .creatingPage, .uploading(done: 0, total: 4),
            .uploading(done: 2, total: 4), .uploading(done: 4, total: 4),
            .writingContent, .updatingProperties, .finishing,
        ]
        let fractions = steps.map(\.fraction)
        #expect(fractions == fractions.sorted())
        #expect(fractions.first! > 0)
        #expect(fractions.last! == 1.0)
    }

    @Test("an entry with no photos skips straight past the upload band")
    func noMediaSkipsUploadBand() {
        #expect(SyncProgress.uploading(done: 0, total: 0).fraction == SyncProgress.writingContent.fraction)
    }

    @Test("photo progress is counted, not guessed")
    func uploadProgressIsProportional() {
        let half = SyncProgress.uploading(done: 2, total: 4).fraction
        let all = SyncProgress.uploading(done: 4, total: 4).fraction
        #expect(half < all)
        #expect(half > SyncProgress.creatingPage.fraction)
    }

    @Test("messages describe the entry, not the API call")
    func messagesAreHumane() {
        #expect(SyncProgress.uploading(done: 1, total: 3).message == "Uploading photo 2 of 3…")
        #expect(SyncProgress.uploading(done: 0, total: 1).message == "Uploading photo…")
        #expect(SyncProgress.findingPage.message == "Opening the entry…")
    }
}

@Suite("Appending to a chosen page")
@MainActor
struct ChosenPageTests {

    /// The regression: picking an existing Notion entry to add to, then getting a brand new
    /// page instead.
    ///
    /// `adoptDestination` treated the chosen page id as stale state from another destination
    /// and wiped it before `ensurePage` ever saw it — so the sync created a page rather than
    /// appending to the one the user picked.
    @Test("a page picked from the destination survives adoption")
    func chosenPageIsNotWipedByAdoption() {
        let draft = EntryDraft()
        draft.updateRawText("More to add")
        let state = draft.syncState(for: .notion)

        state.attachToExistingPage("their-page-id", title: "My Notion Journal 3/25/22")
        // First sync against this destination: fingerprint is still unset.
        let reset = state.adoptDestination("real-workspace")

        #expect(reset == false, "nothing was stale — the page came from this destination")
        #expect(state.externalId == "their-page-id", "the chosen page must survive")
        #expect(state.destinationFingerprint == "real-workspace")
    }

    @Test("the chosen page's name is kept for the UI to show")
    func keepsPageTitle() {
        let state = SyncState(target: .notion)
        state.attachToExistingPage("p1", title: "My Notion Journal 3/25/22")
        #expect(state.externalTitle == "My Notion Journal 3/25/22")
    }

    @Test("unlinking forgets the name along with the page")
    func unlinkClearsTitle() {
        let state = SyncState(target: .notion)
        state.attachToExistingPage("p1", title: "Somewhere")
        state.unlinkFromDestination()
        #expect(state.externalTitle == nil)
        #expect(state.externalId == nil)
    }

    /// The protection that still has to work: a page this app created against a *different*
    /// workspace is genuinely stale and must be discarded.
    @Test("a page we created ourselves is still discarded on a destination change")
    func ownedPageStillResets() {
        let state = SyncState(target: .notion)
        state.adoptDestination("workspace-a")
        state.externalId = "page-we-made"

        #expect(state.adoptDestination("workspace-b"))
        #expect(state.externalId == nil)
    }

    @Test("appending actually reaches the chosen page")
    func appendReachesChosenPage() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let store = DraftStore(container: container)
        let draft = try store.createDraft()
        try store.updateRawText("An addition", for: draft)
        draft.syncState(for: .notion).attachToExistingPage("their-page-id", title: "Theirs")

        let api = StubNotionAPI()
        let files = MediaFileStore(root: FileManager.default.temporaryDirectory)
        let sut = SyncCoordinator(store: store, fileStore: files, notion: api)

        #expect(await sut.sync(draftId: draft.id) == .synced)
        #expect(draft.syncState(for: .notion).externalId == "their-page-id")
    }
}
