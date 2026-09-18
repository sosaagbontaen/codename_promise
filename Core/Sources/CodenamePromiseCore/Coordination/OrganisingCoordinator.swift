import Foundation
import Observation

/// Runs the organising pass over a draft.
///
/// Same shape as the other three coordinators: snapshot `Sendable` values on the main actor,
/// await the service, re-fetch by `UUID`, and discard the result if the content moved on
/// while it ran (ADR-009a, ADR-016).
///
/// What differs is the promise being kept. `FormattingCoordinator` enforces "AI assists,
/// never authors" by forbidding any path to `rawText`. Organising is allowed to do what
/// formatting may not — drop "um", put minute eight beside minute one — so the same tenet is
/// kept a different way:
///
///  1. **`rawText` is still never written.** The organised entry is stored separately, and
///     what the person actually said stays exactly as they said it.
///  2. **Every line is accounted for**, verified on the server by `dropguard` before it ever
///     reaches here, and the citations that prove it are stored with the result.
///
/// So the arrangement is disposable and the words are not. Organising can be run again, or
/// ignored, and nothing is lost either way.
@MainActor
@Observable
public final class OrganisingCoordinator {
    public private(set) var inFlight: Set<UUID> = []
    public private(set) var lastError: String?

    /// Set when the last attempt failed for a reason worth showing. Cleared on success.
    public private(set) var blockedReason: String?

    private let store: DraftStore
    private let service: any OrganisingService

    /// How long to wait before the one retry. Long enough for a token bucket to refill
    /// rather than a token gesture — and injectable, because a test asserting the retry
    /// happens should not sit through the wait to find out.
    private let retryAfter: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        store: DraftStore,
        service: any OrganisingService,
        retryAfter: Duration = .seconds(20),
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.store = store
        self.service = service
        self.retryAfter = retryAfter
        self.sleep = sleep
    }

    public func isOrganising(_ draftId: UUID) -> Bool { inFlight.contains(draftId) }

    /// Whether organising would produce something new.
    ///
    /// False while a recording is still waiting to be transcribed: organising a transcript
    /// that is about to grow would arrange half a day and look finished. See ADR-002.
    public func canOrganise(draftId: UUID) -> Bool {
        guard let draft = try? store.draft(id: draftId) else { return false }
        guard !draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return draft.orderedAudioCaptures.allSatisfy(\.isSafeToDelete)
    }

    @discardableResult
    public func organise(draftId: UUID) async -> OrganisingOutcome {
        guard !inFlight.contains(draftId) else { return .alreadyRunning }
        guard let draft = try? store.draft(id: draftId) else { return .vanished }

        let transcript = draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return .nothingToOrganise }

        // Snapshot before the await, so a result that arrives after more talking is
        // recognisable as stale rather than merely plausible.
        let request = OrganiseRequest(
            draftId: draftId,
            transcript: draft.content.rawText,
            contentHash: draft.contentHash
        )

        inFlight.insert(draftId)
        defer { inFlight.remove(draftId) }

        do {
            let result = try await attempt(request)

            guard let draft = try? store.draft(id: draftId) else { return .vanished }
            guard draft.contentHash == result.sourceContentHash else {
                blockedReason = "You've said more since. Organise again when you're ready."
                return .discardedStale
            }
            guard !result.organised.isEmpty else {
                blockedReason = nil
                return .nothingToOrganise
            }

            try store.applyOrganised(result.organised, to: draft)
            blockedReason = nil
            lastError = nil
            return .organised
        } catch let error as APIError {
            // Nothing was written and the transcript was never at risk, so this is a delay
            // rather than a loss, and the message must not imply otherwise.
            let message = error.isRetryable ? Self.busyMessage : error.userFacingMessage
            blockedReason = message
            lastError = message
            return error.isRetryable ? .deferred(message) : .failed(message)
        } catch {
            blockedReason = error.localizedDescription
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    /// Tries once, waits, tries once more.
    ///
    /// "Server is busy. Will try again shortly." was shown for a retryable failure and
    /// nothing ever tried again — the message described a behaviour the app did not have, so
    /// a long entry looked like it had simply stopped. Sync retries because a person presses
    /// Send again and the queue picks it up; organising has no queue behind it.
    ///
    /// One retry, not a loop. The backend already waits out the provider's rate limit for
    /// over a minute before giving up, so a busy answer reaching here means the wait was
    /// genuinely not enough, and grinding away at it would only hold somebody in front of a
    /// spinner for minutes.
    private func attempt(_ request: OrganiseRequest) async throws -> OrganiseResult {
        do {
            return try await service.organise(request)
        } catch let error as APIError where error.isRetryable {
            try? await sleep(retryAfter)
            return try await service.organise(request)
        }
    }

    /// Said after the retry, so it does not promise a third attempt that is not coming.
    private static let busyMessage =
        "The server is busy right now. Try arranging again in a minute."
}

public enum OrganisingOutcome: Sendable, Equatable {
    case organised
    /// Succeeded, but more was said while it ran, so the arrangement was thrown away rather
    /// than applied to words it was not built from.
    case discardedStale
    case deferred(String)
    case failed(String)
    case nothingToOrganise
    case vanished
    case alreadyRunning
}
