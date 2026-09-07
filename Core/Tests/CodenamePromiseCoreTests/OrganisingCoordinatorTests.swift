import Foundation
import Testing
@testable import CodenamePromiseCore

/// Organising a draft, and everything that must not happen while it runs.
@Suite("Organising coordinator")
@MainActor
struct OrganisingCoordinatorTests {

    final class StubOrganiser: OrganisingService, @unchecked Sendable {
        var result: OrganisedEntry = OrganisedEntry(
            sentences: ["One thing.", "Um.", "Two things."],
            sections: [.init(heading: "Work", body: "One thing. Two things.", sources: [1, 3])],
            dropped: [2],
            version: "organise-test"
        )
        var error: Error?
        /// The hash to echo back. Nil means echo the request's own, which is the honest case.
        var echoHash: String?
        private(set) var calls = 0

        func organise(_ request: OrganiseRequest) async throws -> OrganiseResult {
            calls += 1
            if let error { throw error }
            return OrganiseResult(
                draftId: request.draftId,
                organised: result,
                sourceContentHash: echoHash ?? request.contentHash
            )
        }
    }

    private func makeStore() throws -> DraftStore {
        DraftStore(container: try ModelContainerFactory.makeInMemoryContainer())
    }

    private func draftWithText(_ store: DraftStore, _ text: String) throws -> EntryDraft {
        let draft = try store.createDraft()
        try store.updateRawText(text, for: draft)
        return draft
    }

    @Test("an arrangement is stored with the lines it came from")
    func organisesAndStores() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        let draft = try draftWithText(store, "One thing. Um. Two things.")

        let outcome = await OrganisingCoordinator(store: store, service: service)
            .organise(draftId: draft.id)

        #expect(outcome == .organised)
        let organised = try #require(draft.organised)
        #expect(organised.sections.first?.sources == [1, 3])
        #expect(organised.spokenLines(for: organised.sections[0]) == ["One thing.", "Two things."])
        #expect(draft.organiserVersion == "organise-test")
    }

    /// The tenet, kept a different way from formatting: the arrangement is disposable and
    /// the words are not.
    @Test("what the person actually said is never touched")
    func rawTextIsUntouched() async throws {
        let store = try makeStore()
        let draft = try draftWithText(store, "One thing. Um. Two things.")

        _ = await OrganisingCoordinator(store: store, service: StubOrganiser())
            .organise(draftId: draft.id)

        #expect(draft.content.rawText == "One thing. Um. Two things.",
                "organising rearranges a copy; the transcript stays exactly as spoken")
    }

    /// ADR-016. Bumping updatedAt here would re-dirty the draft the instant the arrangement
    /// landed, re-triggering the sync that just finished.
    @Test("storing an arrangement does not mark the entry as edited")
    func doesNotBumpUpdatedAt() async throws {
        let store = try makeStore()
        let draft = try draftWithText(store, "One thing. Um. Two things.")
        let before = draft.updatedAt

        _ = await OrganisingCoordinator(store: store, service: StubOrganiser())
            .organise(draftId: draft.id)

        #expect(draft.updatedAt == before)
    }

    /// The one that matters most. Someone keeps talking while the request is in flight, and
    /// an arrangement of words they have since changed would misrepresent them.
    @Test("a result built from older words is discarded, not applied")
    func discardsStaleResult() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        service.echoHash = "a-hash-from-before"
        let draft = try draftWithText(store, "One thing.")

        let coordinator = OrganisingCoordinator(store: store, service: service)
        let outcome = await coordinator.organise(draftId: draft.id)

        #expect(outcome == .discardedStale)
        #expect(draft.organised == nil, "nothing is better than an arrangement of the wrong words")
        #expect(coordinator.blockedReason?.contains("said more since") == true)
    }

    @Test("an empty entry is not sent anywhere")
    func emptyEntryIsNotSent() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        let draft = try store.createDraft()

        let outcome = await OrganisingCoordinator(store: store, service: service)
            .organise(draftId: draft.id)

        #expect(outcome == .nothingToOrganise)
        #expect(service.calls == 0)
    }

    /// ADR-002. A recording still waiting to be transcribed is words that are about to
    /// arrive; arranging without them would produce half a day that looks complete.
    @Test("organising waits for a recording that has not been transcribed")
    func waitsForPendingAudio() async throws {
        let store = try makeStore()
        let files = try MediaFileStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("org-\(UUID().uuidString)"))
        let draft = try draftWithText(store, "One thing so far.")

        _ = try store.attachAudioCapture(
            data: Data("audio".utf8), fileExtension: "m4a", durationSeconds: 3,
            to: draft, fileStore: files
        )

        let coordinator = OrganisingCoordinator(store: store, service: StubOrganiser())
        #expect(coordinator.canOrganise(draftId: draft.id) == false)
    }

    @Test("a retryable failure is a delay, and says so")
    func retryableFailureIsDeferred() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        service.error = APIError.offline
        let draft = try draftWithText(store, "One thing.")

        let coordinator = OrganisingCoordinator(store: store, service: service)
        let outcome = await coordinator.organise(draftId: draft.id)

        guard case .deferred(let message) = outcome else {
            Issue.record("offline should defer, not fail: \(outcome)")
            return
        }
        #expect(!message.lowercased().contains("lost"),
                "nothing was lost, and the message must never suggest it was")
        #expect(draft.organised == nil)
    }

    @Test("two runs at once do not both go")
    func doesNotRunTwice() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        let draft = try draftWithText(store, "One thing.")
        let coordinator = OrganisingCoordinator(store: store, service: service)

        // The id, not the model. A `@Model` may not cross a concurrency boundary, which is
        // ADR-009a and which the compiler enforces here rather than trusting anyone.
        let id = draft.id
        async let first = coordinator.organise(draftId: id)
        async let second = coordinator.organise(draftId: id)
        let outcomes = await [first, second]

        #expect(outcomes.contains(.alreadyRunning) || service.calls == 1)
    }

    @Test("organising again replaces the previous arrangement")
    func reorganiseReplaces() async throws {
        let store = try makeStore()
        let service = StubOrganiser()
        let draft = try draftWithText(store, "One thing. Um. Two things.")
        let coordinator = OrganisingCoordinator(store: store, service: service)

        _ = await coordinator.organise(draftId: draft.id)
        service.result = OrganisedEntry(
            sentences: ["One thing.", "Um.", "Two things."],
            sections: [.init(heading: "Rethought", body: "Two things.", sources: [3])],
            dropped: [1, 2],
            version: "organise-test-2"
        )
        _ = await coordinator.organise(draftId: draft.id)

        #expect(draft.organised?.sections.first?.heading == "Rethought")
        #expect(draft.organiserVersion == "organise-test-2")
    }
}
