import Foundation

// Service boundaries deal in `Sendable` value types only. No `@Model` object ever crosses
// an `await` — that's the whole point. A service that took an `EntryDraft`, awaited the
// network and mutated it on resume would be a data race that only shows up on slow
// connections; making the boundary DTO-shaped means the compiler rejects that shape under
// Swift 6. Callers re-fetch by UUID on the main actor and apply results via `DraftStore`.
// See ADR-009a.

// MARK: - Transcription

public struct TranscriptionRequest: Sendable, Hashable {
    /// Resolved local file URL of already-persisted audio. The audio is on disk before this
    /// request is built, so failure here costs convenience and never content. See ADR-002.
    public let audioURL: URL
    public let captureId: UUID

    public init(audioURL: URL, captureId: UUID) {
        self.audioURL = audioURL
        self.captureId = captureId
    }
}

public struct TranscriptionResult: Sendable, Hashable {
    public let captureId: UUID
    public let text: String

    public init(captureId: UUID, text: String) {
        self.captureId = captureId
        self.text = text
    }
}

public protocol TranscriptionService: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

// MARK: - Formatting

public struct FormatRequest: Sendable, Hashable {
    public let draftId: UUID
    /// A snapshot, taken on the main actor before the call. The user may keep typing while
    /// this is in flight; the result is applied only if it still matches. See ADR-016.
    public let rawText: String
    public let contentHash: String

    public init(draftId: UUID, rawText: String, contentHash: String) {
        self.draftId = draftId
        self.rawText = rawText
        self.contentHash = contentHash
    }
}

public struct FormatResult: Sendable, Hashable {
    public let draftId: UUID
    public let formattedText: String
    /// Which prompt produced this, so output stays reproducible when the prompt changes.
    public let formatterVersion: String
    /// Echo of the request's hash, so a stale result can be discarded rather than clobber
    /// newer input.
    public let sourceContentHash: String

    public init(
        draftId: UUID,
        formattedText: String,
        formatterVersion: String,
        sourceContentHash: String
    ) {
        self.draftId = draftId
        self.formattedText = formattedText
        self.formatterVersion = formatterVersion
        self.sourceContentHash = sourceContentHash
    }
}

public protocol FormattingService: Sendable {
    func format(_ request: FormatRequest) async throws -> FormatResult
}

// MARK: - Notion

/// The idempotency key every mutating destination call must carry.
///
/// `insert-content` is not naturally idempotent: a lost 200 followed by a retry inserts the
/// entry twice. The backend caches results by this key and replays rather than re-writing.
/// The key is stable across retries of the same content — see `SyncState.beginAttempt`.
public struct IdempotencyKey: Sendable, Hashable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(attemptId: String, step: String) { self.rawValue = "\(attemptId):\(step)" }
}

public struct EnsurePageRequest: Sendable, Hashable {
    public let draftId: UUID
    /// The day the entry is about, which is what identifies the destination page — not the
    /// creation instant. See ADR-006.
    public let entryDate: CalendarDay
    public let title: String?
    public let existingExternalId: String?
    public let idempotencyKey: IdempotencyKey

    public init(
        draftId: UUID,
        entryDate: CalendarDay,
        title: String?,
        existingExternalId: String?,
        idempotencyKey: IdempotencyKey
    ) {
        self.draftId = draftId
        self.entryDate = entryDate
        self.title = title
        self.existingExternalId = existingExternalId
        self.idempotencyKey = idempotencyKey
    }
}

public struct UploadFileRequest: Sendable, Hashable {
    public let mediaId: UUID
    public let fileURL: URL
    public let idempotencyKey: IdempotencyKey

    public init(mediaId: UUID, fileURL: URL, idempotencyKey: IdempotencyKey) {
        self.mediaId = mediaId
        self.fileURL = fileURL
        self.idempotencyKey = idempotencyKey
    }
}

/// An uploaded file and what it should become in the destination.
///
/// The kind travels with the id because a photo in a generic file block renders as a
/// download link rather than a picture — a worse journal for no reason.
public struct AttachedFile: Sendable, Hashable {
    public let id: String
    public let kind: MediaKind

    public init(id: String, kind: MediaKind) {
        self.id = id
        self.kind = kind
    }
}

public struct InsertContentRequest: Sendable, Hashable {
    public let pageId: String
    /// Markdown-ish text. Conversion to destination blocks happens server-side so the
    /// client never learns Notion's block schema — and so block/length chunking lives in
    /// one place. See ADR-017.
    public let formattedText: String
    public let attachedFiles: [AttachedFile]
    /// Blocks already written by an earlier, interrupted attempt. Lets the server replace
    /// rather than append. See ADR-005.
    public let previouslyInsertedBlockIds: [String]
    public let idempotencyKey: IdempotencyKey

    public init(
        pageId: String,
        formattedText: String,
        attachedFiles: [AttachedFile],
        previouslyInsertedBlockIds: [String],
        idempotencyKey: IdempotencyKey
    ) {
        self.pageId = pageId
        self.formattedText = formattedText
        self.attachedFiles = attachedFiles
        self.previouslyInsertedBlockIds = previouslyInsertedBlockIds
        self.idempotencyKey = idempotencyKey
    }
}

public struct UpdatePropertiesRequest: Sendable, Hashable {
    public let pageId: String
    public let title: String?
    public let entryDate: CalendarDay
    public let idempotencyKey: IdempotencyKey

    public init(pageId: String, title: String?, entryDate: CalendarDay, idempotencyKey: IdempotencyKey) {
        self.pageId = pageId
        self.title = title
        self.entryDate = entryDate
        self.idempotencyKey = idempotencyKey
    }
}

/// Named for the destination it actually talks to. No `SyncDestination` abstraction until a
/// second destination exists and its shape is known — speculative indirection here would
/// cost more than it saves. Shared retry/lease plumbing lives in destination-neutral types
/// (`SyncState`, `DraftStore`) so extraction stays possible. See ADR-023.
public protocol NotionAPI: Sendable {
    func ensurePage(_ request: EnsurePageRequest) async throws -> String
    func uploadFile(_ request: UploadFileRequest) async throws -> String
    func insertContent(_ request: InsertContentRequest) async throws -> [String]
    func updateProperties(_ request: UpdatePropertiesRequest) async throws
}

// MARK: - Reachability

/// Capture and editing never depend on this. Only dictation transcription, formatting and
/// sync do, and each must degrade visibly rather than silently. See ADR-019a.
public protocol NetworkReachability: Sendable {
    var isReachable: Bool { get }
}
