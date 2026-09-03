import Foundation
import Observation

/// Runs the AI structuring pass over a draft.
///
/// The tenet this enforces is "AI assists, never authors". Two mechanisms carry it:
///
///  1. There is no code path from here to `rawText`. Results go to `formattedText` only, via
///     `DraftStore.applyFormatting`. (Invariant 3)
///  2. A result derived from text the user has since changed is **discarded**, not applied.
///     Structuring words the user no longer has written would misrepresent them, which is the
///     precise failure the tenet exists to prevent. (ADR-016)
@MainActor
@Observable
public final class FormattingCoordinator {
    public private(set) var inFlight: Set<UUID> = []
    public private(set) var lastError: String?

    /// Set when the last attempt failed for a reason worth showing — offline, unconfigured,
    /// server trouble. Cleared on success.
    public private(set) var blockedReason: String?

    private let store: DraftStore
    private let service: any FormattingService

    public init(store: DraftStore, service: any FormattingService) {
        self.store = store
        self.service = service
    }

    public func isFormatting(_ draftId: UUID) -> Bool { inFlight.contains(draftId) }

    @discardableResult
    public func format(draftId: UUID) async -> FormattingOutcome {
        guard !inFlight.contains(draftId) else { return .alreadyRunning }
        guard let draft = try? store.draft(id: draftId) else { return .vanished }

        let rawText = draft.content.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return .nothingToFormat }

        // Snapshot before the await. The request carries the hash it was built from, and the
        // response echoes it back, so a stale result is recognisable rather than plausible.
        let request = FormatRequest(
            draftId: draftId,
            rawText: draft.content.rawText,
            contentHash: draft.contentHash
        )

        inFlight.insert(draftId)
        defer { inFlight.remove(draftId) }

        do {
            let result = try await service.format(request)

            guard let draft = try? store.draft(id: draftId) else { return .vanished }
            guard draft.contentHash == result.sourceContentHash else {
                // The user kept writing. Their words win; this result is simply out of date.
                blockedReason = "You've written more since. Run formatting again when you're ready."
                return .discardedStale
            }

            try store.applyFormatting(
                result.formattedText,
                formatterVersion: result.formatterVersion,
                to: draft
            )
            blockedReason = nil
            lastError = nil
            return .formatted
        } catch let error as APIError {
            blockedReason = error.userFacingMessage
            lastError = error.userFacingMessage
            // Nothing was written, and rawText was never at risk — so this is deferral, not loss.
            return error.isRetryable ? .deferred(error.userFacingMessage) : .failed(error.userFacingMessage)
        } catch {
            blockedReason = error.localizedDescription
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }
}

public enum FormattingOutcome: Sendable, Equatable {
    case formatted
    /// Succeeded, but the user edited while it ran, so the result was thrown away rather than
    /// applied to words it wasn't derived from.
    case discardedStale
    case deferred(String)
    case failed(String)
    case nothingToFormat
    case vanished
    case alreadyRunning
}
