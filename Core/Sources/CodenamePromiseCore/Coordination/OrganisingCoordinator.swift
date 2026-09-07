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

    public init(store: DraftStore, service: any OrganisingService) {
        self.store = store
        self.service = service
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
            let result = try await service.organise(request)

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
            blockedReason = error.userFacingMessage
            lastError = error.userFacingMessage
            // Nothing was written and the transcript was never at risk, so this is a delay
            // rather than a loss, and the message must not imply otherwise.
            return error.isRetryable
                ? .deferred(error.userFacingMessage)
                : .failed(error.userFacingMessage)
        } catch {
            blockedReason = error.localizedDescription
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }
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
