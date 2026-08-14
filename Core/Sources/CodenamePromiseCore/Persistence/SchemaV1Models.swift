import Foundation
import SwiftData

/// The models exactly as v1 shipped them.
///
/// These are frozen copies, not live types, and nothing outside the migration plan should
/// ever touch them. They exist because a `VersionedSchema` has to *describe a shape*, and a
/// version that points at the live classes describes whatever those classes happen to say
/// today — which is to say, nothing.
///
/// That is not a theoretical objection. `SchemaV2` was added pointing at the same four
/// classes as `SchemaV1`, so both versions hashed identically, and Core Data rejected the
/// migration outright:
///
/// ```
/// NSInvalidArgumentException: Duplicate version checksums detected.
/// ```
///
/// A version bump with no shape behind it is not a migration, it is a rename. The store on
/// disk still couldn't be opened; the failure just moved. See ADR-008a.
///
/// The nesting is what keeps the entity names right — SwiftData names entities after the
/// simple type name, so `SchemaV1.EntryDraft` is still the `EntryDraft` entity, which is what
/// lets a lightweight stage map v1 rows onto v2 ones.
///
/// **When you add a schema version:** copy the current models into a new
/// `SchemaVN` namespace *before* changing them, and leave the older namespaces alone forever.
extension SchemaV1 {

    @Model
    public final class EntryDraft {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var updatedAt: Date = Date()
        public var entryDateKey: String = CalendarDay.today().rawValue
        public var content: EntryContent = EntryContent()

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.MediaItem.draft)
        public var media: [SchemaV1.MediaItem] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.AudioCapture.draft)
        public var audioCaptures: [SchemaV1.AudioCapture] = []

        @Relationship(deleteRule: .cascade, inverse: \SchemaV1.SyncState.draft)
        public var syncStates: [SchemaV1.SyncState] = []

        public init(id: UUID = UUID(), createdAt: Date = Date(), entryDateKey: String) {
            self.id = id
            self.createdAt = createdAt
            self.updatedAt = createdAt
            self.entryDateKey = entryDateKey
        }
    }

    @Model
    public final class MediaItem {
        public var id: UUID = UUID()
        public var createdAt: Date = Date()
        public var relativePath: String = ""
        public var originalSizeBytes: Int = 0
        public var compressedRelativePath: String?
        public var compressedSizeBytes: Int?
        public var sortIndex: Int = 0
        public var kindRaw: String = MediaKind.photo.rawValue
        public var compressionLevelRaw: String = CompressionLevel.none.rawValue
        public var compressionStatusRaw: String = CompressionStatus.pending.rawValue
        public var uploadStatusRaw: String = UploadStatus.pending.rawValue
        public var uploadStartedAt: Date?
        public var uploadAttemptCount: Int = 0
        public var uploadError: String?

        @Relationship public var draft: SchemaV1.EntryDraft?

        public init(
            id: UUID = UUID(),
            kindRaw: String = MediaKind.photo.rawValue,
            relativePath: String,
            originalSizeBytes: Int = 0
        ) {
            self.id = id
            self.kindRaw = kindRaw
            self.relativePath = relativePath
            self.originalSizeBytes = originalSizeBytes
        }
    }

    @Model
    public final class AudioCapture {
        public var id: UUID = UUID()
        public var recordedAt: Date = Date()
        public var relativePath: String = ""
        public var durationSeconds: Double = 0
        public var sizeBytes: Int = 0
        public var chunkIndex: Int = 0
        public var transcriptionStatusRaw: String = TranscriptionStatus.pending.rawValue
        public var transcript: String?
        public var transcriptionStartedAt: Date?
        public var transcriptionAttemptCount: Int = 0
        public var transcriptionError: String?
        public var mergedIntoDraftAt: Date?

        // Note: no `nextTranscriptionAttemptAt`. That is the point — it arrived in v2.

        @Relationship public var draft: SchemaV1.EntryDraft?

        public init(
            id: UUID = UUID(),
            relativePath: String,
            durationSeconds: Double = 0,
            sizeBytes: Int = 0
        ) {
            self.id = id
            self.relativePath = relativePath
            self.durationSeconds = durationSeconds
            self.sizeBytes = sizeBytes
        }
    }

    @Model
    public final class SyncState {
        public var id: UUID = UUID()
        public var targetRaw: String = SyncTarget.notion.rawValue
        public var statusRaw: String = SyncStatus.pending.rawValue
        public var phaseRaw: String = SyncPhase.notStarted.rawValue
        public var externalId: String?
        public var syncedContentHash: String?
        public var attemptId: String?
        public var attemptContentHash: String?
        public var uploadedFileIds: [String: String] = [:]
        public var insertedBlockIds: [String] = []
        public var startedAt: Date?
        public var lastSyncedAt: Date?
        public var lastSyncError: String?
        public var attemptCount: Int = 0

        // Note: no `destinationFingerprint`, `appendsToExistingPage` or `externalTitle`.
        // All three arrived in v2, all three carry defaults, which is what keeps the
        // migration lightweight.

        @Relationship public var draft: SchemaV1.EntryDraft?

        public init(id: UUID = UUID(), targetRaw: String = SyncTarget.notion.rawValue) {
            self.id = id
            self.targetRaw = targetRaw
        }
    }
}
