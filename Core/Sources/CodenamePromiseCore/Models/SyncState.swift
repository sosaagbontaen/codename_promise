import Foundation
import SwiftData

/// One destination's view of one draft. At most one per `SyncTarget` per draft — enforced
/// by `EntryDraft.syncState(for:)`, which is the only sanctioned way to create these.
///
/// Three fields here exist purely to stop the destination getting corrupted:
///
/// - `attemptId` is the idempotency key. `POST /notion/insert-content` is not idempotent,
///   so a lost 200 followed by a retry would insert the entry twice and leave the user
///   hand-deleting blocks. The key is generated once per logical attempt and reused across
///   retries so the backend can replay the original result. See ADR-003.
/// - `phase` records how far a multi-step sync got, so a retry resumes rather than
///   restarting. Restarting is what duplicates. See ADR-005.
/// - `startedAt` is a lease. Without it, a process death mid-sync leaves `status ==
///   .syncing` forever, and the documented rule for `.syncing` is "don't retry" — a
///   permanently unsyncable draft with no way out. See ADR-004.
@Model
public final class SyncState {
    public private(set) var id: UUID = UUID()

    public private(set) var targetRaw: String = SyncTarget.notion.rawValue
    public private(set) var statusRaw: String = SyncStatus.pending.rawValue
    public private(set) var phaseRaw: String = SyncPhase.notStarted.rawValue

    /// The destination's ID for this entry — a Notion page ID, for instance.
    public var externalId: String?

    /// Content fingerprint at the last *successful* sync. Compared against
    /// `EntryDraft.contentHash` to decide dirtiness. Timestamps cannot do this job; see
    /// `EntryContent.contentHash` and ADR-016.
    public var syncedContentHash: String?

    /// Stable idempotency key for the in-flight attempt. Cleared on success.
    public var attemptId: String?

    /// Destination file IDs already uploaded during this attempt, keyed by media UUID
    /// string, so a resumed sync doesn't re-upload what it already sent.
    public var uploadedFileIds: [String: String] = [:]

    /// Block IDs written by `insert-content`, so a resume can verify or patch instead of
    /// blindly re-inserting.
    public var insertedBlockIds: [String] = []

    /// Which destination the cached IDs above belong to. See `adoptDestination`.
    public var destinationFingerprint: String?

    /// True when `externalId` is a page the user chose rather than one this app created.
    ///
    /// The distinction changes what syncing is allowed to do. On a page we created, rewriting
    /// the title and date is housekeeping. On someone's existing entry it is vandalism — so
    /// properties are left alone and only the blocks this app wrote are ever replaced.
    public var appendsToExistingPage: Bool = false

    /// The destination's own name for the page being appended to, so the UI can say
    /// `Add to "Wednesday 12 Aug"` instead of something abstract about additions.
    public var externalTitle: String?

    public var startedAt: Date?
    public var lastSyncedAt: Date?
    public var lastSyncError: String?
    public var attemptCount: Int = 0

    @Relationship public var draft: EntryDraft?

    public init(id: UUID = UUID(), target: SyncTarget) {
        self.id = id
        self.targetRaw = target.rawValue
    }

    // MARK: - Bridged enums

    public var target: SyncTarget {
        get { SyncTarget(rawValue: targetRaw) ?? .notion }
        set { targetRaw = newValue.rawValue }
    }

    public var status: SyncStatus {
        get { SyncStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    public var phase: SyncPhase {
        get { SyncPhase(rawValue: phaseRaw) ?? .notStarted }
        set { phaseRaw = newValue.rawValue }
    }

    // MARK: - Attempt lifecycle

    /// Begins (or resumes) an attempt for the given content fingerprint.
    ///
    /// The idempotency key is tied to the content being sent: retrying the same content
    /// reuses the key so the backend can dedupe, while changed content earns a fresh key
    /// and a fresh phase because it is genuinely a different write.
    public func beginAttempt(contentHash: String, now: Date = Date()) {
        if attemptContentHash != contentHash {
            attemptContentHash = contentHash
            attemptId = UUID().uuidString
            phase = .notStarted
            // `insertedBlockIds` and `uploadedFileIds` are deliberately NOT cleared. They
            // describe what already exists *in the destination*, not what this attempt has
            // done, so they outlive the attempt that created them. Clearing them would make
            // the next insert append a second copy of the entry beside the first — the same
            // duplication ADR-003 guards against, reached by editing rather than by retrying.
            // Re-uploading unchanged media would likewise orphan a duplicate file.
        } else if attemptId == nil {
            attemptId = UUID().uuidString
        }
        status = .syncing
        startedAt = now
        attemptCount += 1
        lastSyncError = nil
    }

    /// Content fingerprint the current `attemptId` belongs to.
    public var attemptContentHash: String?

    /// Notices a change of destination and discards IDs that no longer mean anything.
    ///
    /// `externalId`, `uploadedFileIds` and `insertedBlockIds` outlive an *attempt* on
    /// purpose — that is what stops a retry duplicating content. They must not outlive a
    /// change of *destination*: IDs issued by one workspace (or by a development stub) are
    /// not stale against another, they are fabrications, and sending them produces errors
    /// that look like the destination's fault.
    ///
    /// Returns true when a reset happened, so callers can say so.
    @discardableResult
    public func adoptDestination(_ fingerprint: String?) -> Bool {
        guard let fingerprint else { return false }
        guard destinationFingerprint != fingerprint else { return false }

        // A page the user just picked from this destination's own listing is not stale state
        // — it came from the very destination being adopted. Clearing it here is what made
        // "add to an existing entry" create a brand new page instead: the chosen page id was
        // wiped before `ensurePage` ever saw it.
        if appendsToExistingPage, externalId != nil {
            destinationFingerprint = fingerprint
            return false
        }

        let hadState = externalId != nil || !uploadedFileIds.isEmpty || !insertedBlockIds.isEmpty
        destinationFingerprint = fingerprint
        externalId = nil
        uploadedFileIds = [:]
        insertedBlockIds = []
        syncedContentHash = nil
        attemptId = nil
        attemptContentHash = nil
        phase = .notStarted
        if status == .synced { status = .pending }
        return hadState
    }

    /// Forgets which remote page this draft belongs to, so the next sync creates a new one.
    ///
    /// Needed because a page reference can be wrong rather than merely stale — an earlier
    /// version of the sync path adopted pages it had not created, binding drafts to entries
    /// the user had written by hand. Clearing the pointer is the only way back: the app
    /// cannot tell retroactively which pages were its own.
    ///
    /// Deliberately does not touch the destination. Nothing is deleted from Notion; the
    /// draft simply stops claiming that page.
    /// Points this draft at an entry the user already has, to add to rather than replace.
    public func attachToExistingPage(_ pageId: String, title: String? = nil) {
        externalId = pageId
        externalTitle = title
        appendsToExistingPage = true
        insertedBlockIds = []
        syncedContentHash = nil
        attemptId = nil
        attemptContentHash = nil
        phase = .notStarted
        status = .pending
        lastSyncError = nil
    }

    public func unlinkFromDestination() {
        externalId = nil
        externalTitle = nil
        appendsToExistingPage = false
        insertedBlockIds = []
        uploadedFileIds = [:]
        syncedContentHash = nil
        attemptId = nil
        attemptContentHash = nil
        phase = .notStarted
        status = .pending
        lastSyncError = nil
    }

    public func advance(to phase: SyncPhase) {
        // Never move backwards: a resumed sync must not undo recorded progress.
        if phase.rank > self.phase.rank { self.phase = phase }
    }

    public func recordUploadedFile(mediaId: UUID, externalFileId: String) {
        uploadedFileIds[mediaId.uuidString] = externalFileId
    }

    public func uploadedFileId(for mediaId: UUID) -> String? {
        uploadedFileIds[mediaId.uuidString]
    }

    public func markSynced(externalId: String, contentHash: String, now: Date = Date()) {
        self.externalId = externalId
        self.syncedContentHash = contentHash
        self.status = .synced
        self.phase = .propertiesUpdated
        self.lastSyncedAt = now
        self.lastSyncError = nil
        self.startedAt = nil
        self.attemptId = nil
        self.attemptContentHash = nil
    }

    public func markFailed(_ message: String) {
        status = .failed
        lastSyncError = message
        startedAt = nil
        // attemptId and phase are deliberately retained: the next retry resumes this
        // same logical attempt rather than starting a duplicate one.
    }

    /// True when a sync claims to be in flight but nothing is actually driving it.
    public func isStale(now: Date = Date(), timeout: TimeInterval) -> Bool {
        guard status == .syncing, let started = startedAt else { return false }
        return now.timeIntervalSince(started) > timeout
    }
}
