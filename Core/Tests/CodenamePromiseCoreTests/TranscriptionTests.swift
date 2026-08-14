import Foundation
import SwiftData
import Testing
@testable import CodenamePromiseCore

// MARK: - Test doubles

/// A transcription service whose behaviour each test dictates.
///
/// An actor rather than a lock-guarded class: it's called from async contexts, where
/// `NSLock` is unavailable by design.
actor StubTranscriptionService: TranscriptionService {
    enum Behaviour {
        case succeed(String)
        case fail(APIError)
    }

    private var behaviour: Behaviour
    private(set) var callCount = 0

    init(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func setBehaviour(_ behaviour: Behaviour) { self.behaviour = behaviour }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        callCount += 1
        switch behaviour {
        case .succeed(let text):
            return TranscriptionResult(captureId: request.captureId, text: text)
        case .fail(let error):
            throw error
        }
    }
}

@Suite("Transcription queue")
@MainActor
struct TranscriptionCoordinatorTests {

    private struct Harness {
        let store: DraftStore
        let files: MediaFileStore
        let draft: EntryDraft
        let capture: AudioCapture
    }

    private func makeHarness(now: Date) throws -> Harness {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cp-stt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = MediaFileStore(root: root)
        let store = DraftStore(container: container, clock: { now })
        let draft = try store.createDraft()
        let capture = try store.attachAudioCapture(
            data: Data(repeating: 0x11, count: 512),
            fileExtension: "m4a",
            durationSeconds: 12,
            to: draft,
            fileStore: files
        )
        return Harness(store: store, files: files, draft: draft, capture: capture)
    }

    @Test("a successful transcription lands in the draft and releases the audio")
    func successMergesTranscript() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let service = StubTranscriptionService(.succeed("Had a good run this morning."))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        let summary = await coordinator.drain()

        #expect(summary.transcribed == 1)
        #expect(h.draft.content.rawText.contains("Had a good run this morning."))
        #expect(h.capture.transcriptionStatus == .transcribed)
        #expect(h.capture.isSafeToDelete)
        #expect(try h.store.dueTranscriptions(now: now).isEmpty)
    }

    /// The founding guarantee, expressed as a test: the network can fail however it likes and
    /// the recording is still there, still queued, still recoverable.
    @Test("an offline failure keeps the audio and schedules a retry")
    func offlineDefersWithoutLoss() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let path = h.capture.relativePath
        let service = StubTranscriptionService(.fail(.offline))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        let summary = await coordinator.drain()

        #expect(summary.transcribed == 0)
        #expect(h.files.exists(path), "the recording must survive a failed transcription")
        #expect(h.capture.transcriptionStatus == .failed)
        #expect(h.capture.isSafeToDelete == false)
        #expect(h.capture.nextTranscriptionAttemptAt != nil, "a retryable failure must be scheduled")
        #expect(coordinator.blockedReason != nil, "the user should be told why the queue stalled")
    }

    @Test("backoff prevents an immediate retry, and the retry succeeds once due")
    func backoffThenSuccess() async throws {
        var now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let service = StubTranscriptionService(.fail(.server(status: 503, message: nil)))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        _ = await coordinator.drain()
        #expect(await service.callCount == 1)

        // Immediately again: nothing is due, so the service must not be called.
        _ = await coordinator.drain()
        #expect(await service.callCount == 1, "backoff must suppress an immediate retry")

        // Once the backoff has elapsed and the server has recovered.
        now = now.addingTimeInterval(600)
        let later = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )
        await service.setBehaviour(.succeed("Second time lucky."))
        let summary = await later.drain()

        #expect(summary.transcribed == 1)
        #expect(await service.callCount == 2)
        #expect(h.draft.content.rawText.contains("Second time lucky."))
    }

    @Test("a permanent failure is not retried forever")
    func permanentFailureStops() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let service = StubTranscriptionService(.fail(.server(status: 400, message: "bad audio")))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        let summary = await coordinator.drain()

        #expect(summary.failed == 1)
        #expect(h.capture.nextTranscriptionAttemptAt == nil)
        #expect(try h.store.dueTranscriptions(now: now.addingTimeInterval(86_400)).count == 1,
                "it stays visible as failed work rather than disappearing")
    }

    @Test("a missing audio file fails permanently instead of looping")
    func missingFileFailsPermanently() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        h.files.delete(relativePaths: [h.capture.relativePath])

        let service = StubTranscriptionService(.succeed("never called"))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        let summary = await coordinator.drain()

        #expect(summary.failed == 1)
        #expect(await service.callCount == 0)
    }

    @Test("deleting the draft mid-flight is handled, not crashed on")
    func vanishedDraftIsSkipped() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let captureId = h.capture.id
        try h.store.delete(h.draft, fileStore: h.files)

        let service = StubTranscriptionService(.succeed("orphaned"))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        let outcome = await coordinator.transcribe(captureId: captureId)

        #expect(outcome == .vanished)
        #expect(await service.callCount == 0)
    }

    /// This test previously asserted that an empty transcript "resolves" the item — marking
    /// it transcribed and merged. That encoded a bug: the recording was quietly retired, the
    /// "waiting to transcribe" notice disappeared, no words appeared and nothing was said.
    /// Hearing nothing is not the same as succeeding.
    @Test("a recording with no audible speech is reported, and its audio kept")
    func emptyTranscriptIsReportedNotSwallowed() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let service = StubTranscriptionService(.succeed("   "))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        _ = await coordinator.drain()

        #expect(h.capture.transcriptionStatus == .failed)
        #expect(h.capture.isSafeToDelete == false, "the audio is still the user's")
        #expect(h.capture.transcriptionError != nil, "and they are told why nothing appeared")
        #expect(h.draft.content.rawText.isEmpty, "silence must not append blank lines")
        #expect(coordinator.blockedReason != nil)
    }

    @Test("silence is not retried on a schedule")
    func silenceDoesNotHammer() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let service = StubTranscriptionService(.succeed(""))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        _ = await coordinator.drain()
        let callsAfterFirst = await service.callCount
        _ = await coordinator.drain()

        // Re-sending identical silence would fail identically forever.
        #expect(await service.callCount == callsAfterFirst)
    }

    @Test("audio is only released once its words are in the draft and it has aged")
    func releaseRespectsSafety() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let h = try makeHarness(now: now)
        let path = h.capture.relativePath
        let service = StubTranscriptionService(.fail(.offline))
        let coordinator = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service, clock: { now }
        )

        _ = await coordinator.drain()
        #expect(try coordinator.releaseTranscribedAudio(olderThan: 0) == 0)
        #expect(h.files.exists(path), "un-merged audio must never be released")

        await service.setBehaviour(.succeed("Now it's safe."))
        let after = TranscriptionCoordinator(
            store: h.store, fileStore: h.files, service: service,
            clock: { now.addingTimeInterval(600) }
        )
        _ = await after.drain()
        #expect(try after.releaseTranscribedAudio(olderThan: 0) == 1)
        #expect(h.files.exists(path) == false)
    }
}

@Suite("API error classification")
struct APIErrorTests {

    @Test("transient failures retry, permanent ones don't")
    func retryability() {
        #expect(APIError.offline.isRetryable)
        #expect(APIError.transport("dropped").isRetryable)
        #expect(APIError.server(status: 503, message: nil).isRetryable)
        #expect(APIError.server(status: 429, message: nil).isRetryable)
        #expect(APIError.server(status: 400, message: nil).isRetryable == false)
        #expect(APIError.unauthorized.isRetryable == false)
        #expect(APIError.decoding("nonsense").isRetryable == false)
    }

    @Test("no user-facing message ever suggests work was lost")
    func messagesAreReassuring() {
        let errors: [APIError] = [
            .notConfigured, .offline, .transport("x"),
            .server(status: 500, message: nil), .server(status: 429, message: nil),
            .decoding("x"), .unauthorized,
        ]
        for error in errors {
            let message = error.userFacingMessage.lowercased()
            #expect(message.contains("lost") == false)
            #expect(message.isEmpty == false)
        }
    }

    @Test("backoff grows and is capped")
    func backoffGrowsThenCaps() {
        let first = RetryPolicy.nextRetryDate(forAttempt: 1, from: Date(timeIntervalSince1970: 0))
        let third = RetryPolicy.nextRetryDate(forAttempt: 3, from: Date(timeIntervalSince1970: 0))
        let huge = RetryPolicy.nextRetryDate(forAttempt: 99, from: Date(timeIntervalSince1970: 0))

        #expect(first.timeIntervalSince1970 == 1)
        #expect(third.timeIntervalSince1970 == 4)
        #expect(huge.timeIntervalSince1970 <= 300)
    }
}
