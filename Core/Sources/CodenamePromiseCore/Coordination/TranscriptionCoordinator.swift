import Foundation
import Observation

/// Drains the queue of recordings waiting to become text.
///
/// This is the payoff for ADR-002. Because the audio was persisted and committed before any
/// network call, this coordinator is allowed to fail in every way — offline, 500, killed
/// mid-request — without costing the user a word. The worst outcome is that a recording stays
/// a recording for a while longer.
///
/// Single consumer by construction: `drain()` returns immediately if a pass is already
/// running, so two overlapping passes can't lease the same capture.
@MainActor
@Observable
public final class TranscriptionCoordinator {
    public private(set) var isRunning = false
    public private(set) var lastError: String?
    /// Set when the queue is stalled for a reason the user should see, rather than a transient
    /// blip worth retrying quietly. See ADR-019a.
    public private(set) var blockedReason: String?

    private let store: DraftStore
    private let fileStore: MediaFileStore
    private let service: any TranscriptionService
    private let clock: () -> Date

    public init(
        store: DraftStore,
        fileStore: MediaFileStore,
        service: any TranscriptionService,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.fileStore = fileStore
        self.service = service
        self.clock = clock
    }

    /// Processes every due recording. Safe to call on launch, after a recording finishes, and
    /// when connectivity returns.
    @discardableResult
    public func drain() async -> DrainSummary {
        guard !isRunning else { return DrainSummary() }
        isRunning = true
        defer { isRunning = false }

        var summary = DrainSummary()

        let due: [UUID]
        do {
            due = try store.dueTranscriptions(now: clock()).map(\.id)
        } catch {
            lastError = error.localizedDescription
            return summary
        }

        for captureId in due {
            switch await transcribe(captureId: captureId) {
            case .transcribed:
                summary.transcribed += 1
            case .deferred:
                summary.deferred += 1
            case .permanentlyFailed:
                summary.failed += 1
            case .vanished:
                summary.skipped += 1
            case .blocked(let reason):
                // Offline, unauthorized, or no backend: the rest of the queue will fail the
                // same way, so stop rather than marking every item failed in turn.
                blockedReason = reason
                summary.deferred += due.count - summary.total + 1
                return summary
            }
        }

        if summary.transcribed > 0 { blockedReason = nil }
        return summary
    }

    public enum Outcome: Equatable, Sendable {
        case transcribed
        case deferred
        case permanentlyFailed
        /// The capture or its draft was deleted while the request was in flight.
        case vanished
        /// Every remaining item would fail the same way, so the pass stopped early.
        case blocked(String)
    }

    func transcribe(captureId: UUID) async -> Outcome {
        // Re-fetch rather than holding a model across the await: the user may delete the
        // draft while this is in flight. See ADR-009a.
        guard let capture = try? store.audioCapture(id: captureId), capture.draft != nil else {
            return .vanished
        }

        let audioURL = fileStore.url(for: capture.relativePath)
        guard fileStore.exists(capture.relativePath) else {
            // Bytes are gone and cannot come back. Recording a permanent failure is the
            // honest outcome; retrying forever would be a lie.
            capture.markTranscriptionFailed("The recording file is missing.")
            try? store.flush()
            return .permanentlyFailed
        }

        capture.markTranscribing(now: clock())
        // Commit the lease before the call so a process death here is recoverable by launch
        // reconciliation rather than invisible. See ADR-004.
        try? store.flush()

        do {
            let result = try await service.transcribe(
                TranscriptionRequest(audioURL: audioURL, captureId: captureId)
            )

            guard let capture = try? store.audioCapture(id: captureId),
                  let draft = capture.draft else {
                return .vanished
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                // Nothing was heard. This used to mark the capture transcribed and merged,
                // which quietly retired the recording, cleared the "waiting to transcribe"
                // notice, added no words, and told the user nothing — a silent success, which
                // is the worst outcome available to an app that promises not to lose things.
                //
                // Instead: keep the audio, say so, and don't retry on a schedule. Re-sending
                // identical silence would fail identically forever, so it waits for the user
                // to ask again rather than burning battery being wrong.
                capture.markTranscriptionFailed(
                    "No speech was heard in this recording. The audio is still saved.",
                    nextAttemptAt: clock().addingTimeInterval(60 * 60 * 24 * 365)
                )
                try store.flush()
                blockedReason = "A recording had no audible speech — it's still saved."
                return .permanentlyFailed
            }

            // One commit sets the transcript, appends it to the draft, and marks the audio
            // releasable — there is no window where the audio looks disposable but its words
            // aren't saved.
            try store.mergeTranscript(text, from: capture, into: draft)
            lastError = nil
            return .transcribed
        } catch let error as APIError {
            return record(error, on: captureId)
        } catch {
            return record(.transport(error.localizedDescription), on: captureId)
        }
    }

    private func record(_ error: APIError, on captureId: UUID) -> Outcome {
        guard let capture = try? store.audioCapture(id: captureId) else { return .vanished }

        let attempt = capture.transcriptionAttemptCount
        if error.isRetryable {
            capture.markTranscriptionFailed(
                error.userFacingMessage,
                nextAttemptAt: RetryPolicy.nextRetryDate(forAttempt: attempt, from: clock())
            )
        } else {
            capture.markTranscriptionFailed(error.userFacingMessage)
        }
        try? store.flush()
        lastError = error.userFacingMessage

        switch error {
        case .notConfigured, .offline, .unauthorized:
            return .blocked(error.userFacingMessage)
        default:
            return error.isRetryable ? .deferred : .permanentlyFailed
        }
    }

    /// Frees disk for recordings whose words are safely in the draft.
    ///
    /// Deliberately **not** called automatically. Deleting the original audio is irreversible,
    /// and a user who dislikes a transcript may well want to hear the recording again — so
    /// this is a decision to surface in settings, not one to make silently at launch.
    /// Retention policy is still open; see ADR-024.
    @discardableResult
    public func releaseTranscribedAudio(olderThan age: TimeInterval) throws -> Int {
        let cutoff = clock().addingTimeInterval(-age)
        var released = 0
        for capture in try store.releasableAudioCaptures() {
            guard let mergedAt = capture.mergedIntoDraftAt, mergedAt < cutoff else { continue }
            // Skip anything already reclaimed, so repeat calls don't inflate the count.
            let present = capture.ownedRelativePaths.filter { fileStore.exists($0) }
            guard !present.isEmpty else { continue }
            fileStore.delete(relativePaths: present)
            released += 1
        }
        try store.flush()
        return released
    }
}

public struct DrainSummary: Sendable, Hashable {
    public var transcribed = 0
    public var deferred = 0
    public var failed = 0
    public var skipped = 0

    public var total: Int { transcribed + deferred + failed + skipped }
    public var isEmpty: Bool { total == 0 }
}
