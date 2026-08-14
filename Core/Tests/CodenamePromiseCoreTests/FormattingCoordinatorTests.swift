import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

/// Returns a deterministic "structured" version, or fails on demand.
actor StubFormattingService: FormattingService {
    private(set) var callCount = 0
    private(set) var receivedRawText: [String] = []
    private var failure: APIError?

    func setFailure(_ error: APIError?) { failure = error }

    func format(_ request: FormatRequest) async throws -> FormatResult {
        callCount += 1
        receivedRawText.append(request.rawText)
        if let failure { throw failure }
        return FormatResult(
            draftId: request.draftId,
            formattedText: "- " + request.rawText.replacingOccurrences(of: ". ", with: "\n- "),
            formatterVersion: "wwwt-2026-08",
            sourceContentHash: request.contentHash
        )
    }
}

/// Main-actor stub whose hook fires mid-call, for "the user kept typing" without racing.
@MainActor
final class HookedFormattingService: FormattingService {
    var duringCall: (() async -> Void)?

    func format(_ request: FormatRequest) async throws -> FormatResult {
        await duringCall?()
        return FormatResult(
            draftId: request.draftId,
            formattedText: "- structured version",
            formatterVersion: "wwwt-2026-08",
            sourceContentHash: request.contentHash
        )
    }
}

@Suite("Formatting")
@MainActor
struct FormattingCoordinatorTests {

    private func makeStore(now: Date) throws -> DraftStore {
        DraftStore(container: try ModelContainerFactory.makeInMemoryContainer(), clock: { now })
    }

    @Test("formatting writes formattedText and records which prompt produced it")
    func formatsAndVersions() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("Ran five miles. Fixed the sync bug.", for: draft)

        let sut = FormattingCoordinator(store: store, service: StubFormattingService())
        #expect(await sut.format(draftId: draft.id) == .formatted)

        #expect(draft.content.formattedText?.contains("- Ran five miles") == true)
        #expect(draft.content.formatterVersion == "wwwt-2026-08")
    }

    /// Invariant 3. The single most important property in the app after durability.
    @Test("formatting never alters the user's own words")
    func rawTextIsUntouched() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        let original = "i rambled a bit and thats fine honestly"
        try store.updateRawText(original, for: draft)

        let sut = FormattingCoordinator(store: store, service: StubFormattingService())
        _ = await sut.format(draftId: draft.id)

        #expect(draft.content.rawText == original)
    }

    @Test("the service receives the raw text verbatim")
    func serviceSeesRawText() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("  leading and trailing whitespace matters  ", for: draft)

        let service = StubFormattingService()
        let sut = FormattingCoordinator(store: store, service: service)
        _ = await sut.format(draftId: draft.id)

        #expect(await service.receivedRawText == ["  leading and trailing whitespace matters  "])
    }

    /// If the result were applied anyway, the app would be presenting structure derived from
    /// words the user no longer has written — authoring, not assisting.
    @Test("a result that arrives after the user has written more is discarded")
    func staleResultIsDiscarded() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("First thought.", for: draft)

        let service = HookedFormattingService()
        let sut = FormattingCoordinator(store: store, service: service)
        service.duringCall = {
            try? store.updateRawText("First thought. And a second one.", for: draft)
        }

        #expect(await sut.format(draftId: draft.id) == .discardedStale)
        #expect(draft.content.formattedText == nil, "stale structure must not be applied")
        #expect(draft.content.rawText == "First thought. And a second one.")
        #expect(sut.blockedReason != nil, "and the user is told why nothing appeared")
    }

    @Test("an empty draft is not sent for formatting")
    func emptyDraftSkipped() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("   \n  ", for: draft)

        let service = StubFormattingService()
        let sut = FormattingCoordinator(store: store, service: service)

        #expect(await sut.format(draftId: draft.id) == .nothingToFormat)
        #expect(await service.callCount == 0)
    }

    @Test("a transient failure is deferred and costs nothing")
    func transientFailureIsDeferred() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("Something worth keeping.", for: draft)

        let service = StubFormattingService()
        await service.setFailure(.offline)
        let sut = FormattingCoordinator(store: store, service: service)

        let outcome = await sut.format(draftId: draft.id)

        #expect(outcome == .deferred(APIError.offline.userFacingMessage))
        #expect(draft.content.rawText == "Something worth keeping.")
        #expect(draft.content.formattedText == nil)
        #expect(sut.blockedReason?.contains("Offline") == true)
    }

    @Test("a permanent failure is reported as failed, not retried forever")
    func permanentFailureIsFinal() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("Something worth keeping.", for: draft)

        let service = StubFormattingService()
        await service.setFailure(.server(status: 400, message: "bad prompt"))
        let sut = FormattingCoordinator(store: store, service: service)

        guard case .failed = await sut.format(draftId: draft.id) else {
            Issue.record("a 4xx must not be presented as retryable")
            return
        }
    }

    @Test("no failure message ever implies work was lost")
    func messagesNeverImplyLoss() {
        let errors: [APIError] = [
            .notConfigured, .offline, .transport("boom"),
            .server(status: 500, message: nil), .server(status: 429, message: nil),
            .decoding("bad json"), .unauthorized,
        ]
        for error in errors {
            let message = error.userFacingMessage.lowercased()
            #expect(!message.contains("lost"))
            #expect(!message.contains("discarded"))
            #expect(!message.contains("deleted"))
        }
    }

    @Test("re-formatting replaces the previous structure rather than accumulating")
    func reformattingReplaces() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("One thing.", for: draft)

        let sut = FormattingCoordinator(store: store, service: StubFormattingService())
        _ = await sut.format(draftId: draft.id)
        let first = draft.content.formattedText

        try store.updateRawText("One thing. Then another.", for: draft)
        _ = await sut.format(draftId: draft.id)

        #expect(draft.content.formattedText != first)
        #expect(draft.content.formattedText?.contains("Then another") == true)
    }

    @Test("formatting makes the draft dirty for sync again")
    func formattingRedirtiesSync() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try makeStore(now: now)
        let draft = try store.createDraft()
        try store.updateRawText("Worth pushing.", for: draft)
        draft.syncState(for: .notion).markSynced(externalId: "page-1", contentHash: draft.contentHash)
        #expect(draft.needsSync(to: .notion) == false)

        let sut = FormattingCoordinator(store: store, service: StubFormattingService())
        _ = await sut.format(draftId: draft.id)

        #expect(draft.needsSync(to: .notion), "the destination should receive the structured version")
    }
}
